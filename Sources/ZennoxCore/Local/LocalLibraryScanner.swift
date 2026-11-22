import Foundation

extension ScanReport {
    public init() {}
}

public struct ScanReport: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var moved = 0
    public var unchanged = 0
    public var missing = 0
    public var skipped = 0          // audio extension but not readable as audio
    public var rootInaccessible = false
}

/// Indexes a local folder/file root into the library without copying, moving or deleting anything.
/// Rescans are incremental: unchanged files (same size and modification time) are not re-read;
/// renamed or moved files keep their track (and so their favorites and playlist entries).
public final class LocalLibraryScanner {
    public static let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "mp4", "aac", "alac", "ogg", "oga", "opus",
                                                      "wav", "wave", "aif", "aiff", "aifc"]
    private let store: LibraryStore
    private let files: FileAccess
    private let makeExternalID: () -> String

    public init(store: LibraryStore, files: FileAccess = LocalFileSystem(),
                makeExternalID: @escaping () -> String = { "local:" + UUID().uuidString }) {
        self.store = store
        self.files = files
        self.makeExternalID = makeExternalID
    }

    public func scan(root: RootID, path: String, source: SourceID, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> ScanReport {
        var report = ScanReport()
        let entries: [FileEntry]
        do {
            entries = try files.listFiles(under: path).filter {
                Self.audioExtensions.contains(($0.path as NSString).pathExtension.lowercased())
            }
        } catch {
            try store.setRootStatus(.inaccessible, for: root, scannedAt: now)
            report.rootInaccessible = true
            return report
        }

        let known = try store.knownFiles(in: root)
        var byIdentity: [String: KnownFile] = [:]
        var byPath: [String: KnownFile] = [:]
        for k in known {
            if let id = k.identity { byIdentity[id] = k }
            if let p = k.path { byPath[p] = k }
        }
        var seen = Set<TrackID>()

        for chunk in stride(from: 0, to: entries.count, by: 200).map({ Array(entries[$0..<min($0 + 200, entries.count)]) }) {
            try store.batch {
                for entry in chunk {
                    let match = entry.identity.flatMap { byIdentity[$0] } ?? byPath[entry.path]
                    if let k = match, !seen.contains(k.trackID) {
                        seen.insert(k.trackID)
                        let sameContent = k.size == entry.size && k.modified == entry.modified
                        if sameContent && k.path == entry.path && k.status == .ok {
                            report.unchanged += 1
                        } else if sameContent {
                            try store.updateLocation(k.trackID, path: entry.path, identity: entry.identity, modified: entry.modified)
                            if k.path == entry.path { report.unchanged += 1 } else { report.moved += 1 }
                        } else if let input = readTrack(entry, externalID: k.externalID) {
                            _ = try store.upsertLocalTrack(input, source: source, root: root, identity: entry.identity, modified: entry.modified)
                            report.updated += 1
                        } else {
                            try store.setStatus(.inaccessible, for: k.trackID)
                            report.skipped += 1
                        }
                    } else if let input = readTrack(entry, externalID: makeExternalID()) {
                        let id = try store.upsertLocalTrack(input, source: source, root: root, identity: entry.identity, modified: entry.modified)
                        seen.insert(id)
                        report.added += 1
                    } else {
                        report.skipped += 1
                    }
                }
            }
        }

        let gone = known.filter { !seen.contains($0.trackID) && $0.status != .missing }.map(\.trackID)
        try store.markMissing(gone)
        report.missing = gone.count
        try store.setRootStatus(.ok, for: root, scannedAt: now)
        return report
    }

    /// Reads a bounded prefix (and tail when the format needs it). Nil if the file is not recognisable audio.
    private func readTrack(_ entry: FileEntry, externalID: String) -> TrackInput? {
        guard let prefix = try? files.read(entry.path, offset: 0, maxBytes: MetadataReader.recommendedPrefixBytes) else { return nil }
        var metadata = MetadataReader.read(prefix, fileSize: entry.size)
        if metadata.needsTailBytes {
            let n = MetadataReader.recommendedTailBytes
            if let tail = try? files.read(entry.path, offset: max(0, entry.size - Int64(n)), maxBytes: n) {
                metadata = MetadataReader.read(prefix, fileSize: entry.size, tail: tail)
            }
        }
        guard metadata.container != .unknown else { return nil }
        let name = (entry.path as NSString).lastPathComponent
        return TrackInput(externalID: externalID, path: entry.path, fileName: name, metadata: metadata, fileSize: entry.size)
    }
}
