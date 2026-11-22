import Foundation

public enum DuplicateReason: String, Sendable, Comparable {
    /// Identical bytes (same MD5): certainly the same file, e.g. a Drive copy of a local file.
    case hash
    /// Same size, same normalised title and artist, duration within 1 s.
    case sizeDurationTags = "size_duration_tags"
    /// Same normalised title and artist, duration within 2 s, different size (e.g. FLAC and MP3 of one song).
    case tagsDuration = "tags_duration"

    var strength: Int {
        switch self { case .hash: return 3; case .sizeDurationTags: return 2; case .tagsDuration: return 1 }
    }

    public static func < (a: DuplicateReason, b: DuplicateReason) -> Bool { a.strength < b.strength }
}

public struct DuplicateGroup: Equatable, Sendable {
    public let id: Int64
    public let reason: DuplicateReason
    public let tracks: [TrackRow]
}

/// Finds likely duplicates across all sources and stores them as suggestions. It only reads and
/// writes library rows: it never deletes, merges or hides tracks. File names are never used as evidence.
public enum DuplicateDetector {
    struct Candidate {
        let id: Int64
        let hash: String?
        let size: Int64?
        let durationMs: Int64?
        let title: String?
        let artist: String?
    }

    /// Recomputes all groups. Cost is linear in library size (bucketed, no all-pairs comparison).
    @discardableResult
    public static func detect(in store: LibraryStore) throws -> Int {
        let db = store.database
        let candidates = try db.query("SELECT id, content_hash, file_size, duration_ms, title, artist FROM track WHERE status = 'ok';")
            .compactMap { r -> Candidate? in
                guard let id = r.int("id") else { return nil }
                return Candidate(id: id, hash: r.text("content_hash"), size: r.int("file_size"), durationMs: r.int("duration_ms"),
                                 title: meaningfulTitle(r.text("title")), artist: normalize(r.text("artist")))
            }
        var dismissed = Set<String>()
        for r in try db.query("SELECT track_a, track_b FROM duplicate_dismissal;") {
            if let a = r.int("track_a"), let b = r.int("track_b") { dismissed.insert("\(a):\(b)") }
        }

        var groups = UnionFind()
        func link(_ a: Int64, _ b: Int64, _ reason: DuplicateReason) {
            guard a != b, !dismissed.contains("\(min(a, b)):\(max(a, b))") else { return }
            groups.union(a, b, reason)
        }

        // 1. Identical content hashes.
        for bucket in Dictionary(grouping: candidates.filter { $0.hash != nil }, by: { $0.hash! }).values where bucket.count > 1 {
            for c in bucket.dropFirst() { link(bucket[0].id, c.id, .hash) }
        }
        // 2 and 3. Same tags (title and artist both required) with close durations.
        let tagged = candidates.filter { $0.title != nil && $0.artist != nil && $0.durationMs != nil }
        for bucket in Dictionary(grouping: tagged, by: { "\($0.title!)|\($0.artist!)" }).values where bucket.count > 1 {
            let sorted = bucket.sorted { $0.durationMs! < $1.durationMs! }
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    let gap = sorted[j].durationMs! - sorted[i].durationMs!
                    if gap > 2_000 { break }
                    let sameSize = sorted[i].size != nil && sorted[i].size == sorted[j].size
                    link(sorted[i].id, sorted[j].id, sameSize && gap <= 1_000 ? .sizeDurationTags : .tagsDuration)
                }
            }
        }

        let members = groups.groups()
        try store.batch {
            try db.run("DELETE FROM duplicate_candidate;")
            for (index, group) in members.enumerated() {
                for id in group.ids {
                    try db.run("INSERT INTO duplicate_candidate (group_id, track_id, reason) VALUES (?, ?, ?);",
                               [.int(Int64(index + 1)), .int(id), .text(group.reason.rawValue)])
                }
            }
        }
        return members.count
    }

    /// Normalises tags for comparison: case, accents and width folded; punctuation collapsed.
    static func normalize(_ text: String?) -> String? {
        guard let text else { return nil }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                out.append(scalar)
                pendingSpace = false
            } else {
                pendingSpace = true
            }
        }
        let result = String(out)
        return result.isEmpty ? nil : result
    }

    /// Generic titles ("Track 01", "01", "Untitled") are not evidence of anything.
    static func meaningfulTitle(_ text: String?) -> String? {
        guard let t = normalize(text) else { return nil }
        let generic = ["track", "audio", "untitled", "unknown", "new recording", "recording"]
        let words = t.split(separator: " ")
        let withoutNumbers = words.filter { !$0.allSatisfy(\.isNumber) }.joined(separator: " ")
        if withoutNumbers.isEmpty || generic.contains(withoutNumbers) { return nil }
        return t
    }
}

private struct UnionFind {
    private var parent: [Int64: Int64] = [:]
    private var reason: [Int64: DuplicateReason] = [:]  // strongest link seen, kept on the root

    mutating func find(_ x: Int64) -> Int64 {
        var root = parent[x] ?? x
        while let next = parent[root], next != root { root = next }
        var node = x
        while let next = parent[node], next != root { parent[node] = root; node = next }
        return root
    }

    mutating func union(_ a: Int64, _ b: Int64, _ why: DuplicateReason) {
        if parent[a] == nil { parent[a] = a }
        if parent[b] == nil { parent[b] = b }
        let ra = find(a), rb = find(b)
        let strongest = [reason[ra], reason[rb], why].compactMap { $0 }.max() ?? why
        if ra != rb { parent[rb] = ra; reason[rb] = nil }
        reason[ra] = strongest
    }

    typealias Group = (ids: [Int64], reason: DuplicateReason)

    /// Groups of two or more, strongest reason first, then by lowest track id.
    mutating func groups() -> [Group] {
        var byRoot: [Int64: [Int64]] = [:]
        for node in Array(parent.keys) { byRoot[find(node), default: []].append(node) }
        var result: [Group] = []
        for (root, ids) in byRoot where ids.count > 1 {
            result.append((ids: ids.sorted(), reason: reason[root] ?? .tagsDuration))
        }
        result.sort { lhs, rhs in
            if lhs.reason.strength != rhs.reason.strength { return lhs.reason.strength > rhs.reason.strength }
            return lhs.ids[0] < rhs.ids[0]
        }
        return result
    }
}

extension LibraryStore {
    /// Stored suggestions, strongest first. Each group lists its tracks with source and quality,
    /// so the person can tell a Drive copy from a local file.
    public func duplicateGroups() throws -> [DuplicateGroup] {
        let rows = try database.query("SELECT group_id, track_id, reason FROM duplicate_candidate ORDER BY group_id, track_id;")
        var order: [Int64] = []
        var members: [Int64: [Int64]] = [:]
        var reasons: [Int64: DuplicateReason] = [:]
        for r in rows {
            guard let g = r.int("group_id"), let t = r.int("track_id") else { continue }
            if members[g] == nil { order.append(g) }
            members[g, default: []].append(t)
            reasons[g] = DuplicateReason(rawValue: r.text("reason") ?? "") ?? .tagsDuration
        }
        return try order.map { g in
            let ids = members[g] ?? []
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let tracks = try database.query("SELECT \(Self.trackColumns) \(Self.trackFrom) WHERE t.id IN (\(placeholders)) ORDER BY t.id;",
                                            ids.map { SQLValue.int($0) }).compactMap(Self.trackRow)
            return DuplicateGroup(id: g, reason: reasons[g] ?? .tagsDuration, tracks: tracks)
        }
    }

    /// "These are not duplicates": remembered for every pair in the group, then the group is removed.
    public func dismissDuplicates(_ tracks: [TrackID]) throws {
        let ids = tracks.map(\.rawValue).sorted()
        try batch {
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    try database.run("INSERT INTO duplicate_dismissal (track_a, track_b, created_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING;",
                                     [.int(ids[i]), .int(ids[j]), .int(currentTime())])
                }
            }
            for id in ids { try database.run("DELETE FROM duplicate_candidate WHERE track_id = ?;", [.int(id)]) }
        }
    }

    public func setContentHash(_ track: TrackID, _ hash: String?) throws {
        try database.run("UPDATE track SET content_hash = ? WHERE id = ?;", [hash.map(SQLValue.text) ?? .null, .int(track.rawValue)])
    }
}

/// Optional, user-started hashing of local files so they can be matched with Drive copies by MD5.
/// Reads each file fully in 1 MB chunks (bounded memory); skips files that already have a hash.
public struct LocalContentHasher {
    private let store: LibraryStore
    private let files: FileAccess
    private let chunk: Int

    public init(store: LibraryStore, files: FileAccess = LocalFileSystem(), chunkBytes: Int = 1 << 20) {
        self.store = store
        self.files = files
        self.chunk = max(4_096, chunkBytes)
    }

    @discardableResult
    public func hashMissing(in root: RootID, isCancelled: () -> Bool = { false }) throws -> Int {
        var hashed = 0
        for known in try store.knownFiles(in: root) where known.status == .ok {
            if isCancelled() { break }
            guard let path = known.path, try hasNoHash(known.trackID),
                  let hex = try? md5(path) else { continue }
            try store.setContentHash(known.trackID, "md5:" + hex)
            hashed += 1
        }
        return hashed
    }

    private func hasNoHash(_ track: TrackID) throws -> Bool {
        try store.database.query("SELECT content_hash FROM track WHERE id = ?;", [.int(track.rawValue)]).first?.text("content_hash") == nil
    }

    func md5(_ path: String) throws -> String {
        var hasher = MD5()
        var offset: Int64 = 0
        while true {
            let bytes = try files.read(path, offset: offset, maxBytes: chunk)
            hasher.update(bytes)
            offset += Int64(bytes.count)
            if bytes.count < chunk { break }
        }
        return hasher.finalizeHex()
    }
}
