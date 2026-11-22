import Foundation

/// A track as shown in lists: everything a row, badge or sort needs, in one query.
public struct TrackRow: Equatable, Sendable {
    public let id: TrackID
    public let title: String
    public let artist: String?
    public let album: String?
    public let albumArtist: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let durationMs: Int64?
    public let codec: Codec
    public let isLossless: Bool
    public let sampleRate: Int?
    public let bitDepth: Int?
    public let status: TrackStatus
    public let sourceKind: SourceKind
    public let path: String?
    public let isFavorite: Bool
}

public struct AlbumRow: Hashable, Sendable {
    public let title: String
    /// Album artist when tagged, else track artist; "" when unknown.
    public let artist: String
    public let trackCount: Int
    public let durationMs: Int64
    public let hasLossless: Bool
}

public struct ArtistRow: Hashable, Sendable {
    public let name: String
    public let trackCount: Int
    public let albumCount: Int
}

public struct FolderRow: Hashable, Sendable {
    public let path: String
    public let trackCount: Int
}

public enum TrackSort: String, Sendable, CaseIterable {
    case title, artist, album, recentlyAdded, duration
}

extension LibraryStore {
    static let trackColumns = """
        t.id, t.title, t.artist, t.album, t.album_artist, t.track_no, t.disc_no, t.duration_ms, t.codec,
        t.is_lossless, t.sample_rate, t.bit_depth, t.status, t.path, s.kind AS source_kind,
        (f.track_id IS NOT NULL) AS is_favorite
        """
    static let trackFrom = """
        FROM track t JOIN source s ON s.id = t.source_id LEFT JOIN favorite f ON f.track_id = t.id
        """

    static func orderClause(_ sort: TrackSort) -> String {
        switch sort {
        case .title: return "t.title COLLATE NOCASE, t.id"
        case .artist: return "coalesce(t.artist, '') = '', t.artist COLLATE NOCASE, t.album COLLATE NOCASE, t.disc_no, t.track_no, t.title COLLATE NOCASE"
        case .album: return "coalesce(t.album, '') = '', t.album COLLATE NOCASE, t.disc_no, t.track_no, t.title COLLATE NOCASE"
        case .recentlyAdded: return "t.added_at DESC, t.id DESC"
        case .duration: return "coalesce(t.duration_ms, 0) DESC, t.title COLLATE NOCASE"
        }
    }

    static func trackRow(_ r: Row) -> TrackRow? {
        guard let id = r.int("id") else { return nil }
        return TrackRow(
            id: TrackID(rawValue: id), title: r.text("title") ?? "", artist: r.text("artist"), album: r.text("album"),
            albumArtist: r.text("album_artist"), trackNumber: r.int("track_no").map { Int($0) },
            discNumber: r.int("disc_no").map { Int($0) }, durationMs: r.int("duration_ms"),
            codec: Codec(rawValue: r.text("codec") ?? "") ?? .unknown, isLossless: r.int("is_lossless") == 1,
            sampleRate: r.int("sample_rate").map { Int($0) }, bitDepth: r.int("bit_depth").map { Int($0) },
            status: TrackStatus(rawValue: r.text("status") ?? "") ?? .ok,
            sourceKind: SourceKind(rawValue: r.text("source_kind") ?? "") ?? .local,
            path: r.text("path"), isFavorite: r.int("is_favorite") == 1)
    }

    private func tracks(_ whereSQL: String = "", _ params: [SQLValue] = [], order: String, limit: Int? = nil, offset: Int = 0) throws -> [TrackRow] {
        var sql = "SELECT \(Self.trackColumns) \(Self.trackFrom) \(whereSQL) ORDER BY \(order)"
        var values = params
        if let limit { sql += " LIMIT ? OFFSET ?"; values += [.int(Int64(limit)), .int(Int64(offset))] }
        return try database.query(sql + ";", values).compactMap(Self.trackRow)
    }

    // MARK: Lists

    public func allTracks(sort: TrackSort = .title, limit: Int? = nil, offset: Int = 0) throws -> [TrackRow] {
        try tracks(order: Self.orderClause(sort), limit: limit, offset: offset)
    }

    public func favoriteTracks() throws -> [TrackRow] {
        try tracks("WHERE f.track_id IS NOT NULL", order: "f.created_at DESC, t.id DESC")
    }

    public func recentlyAdded(limit: Int = 50) throws -> [TrackRow] {
        try tracks(order: Self.orderClause(.recentlyAdded), limit: limit)
    }

    /// Each track once, most recent play first.
    public func recentlyPlayed(limit: Int = 50) throws -> [TrackRow] {
        let sql = """
            SELECT \(Self.trackColumns), h.last_played
            \(Self.trackFrom)
            JOIN (SELECT track_id, max(played_at) AS last_played FROM playback_history GROUP BY track_id) h ON h.track_id = t.id
            ORDER BY h.last_played DESC, t.id DESC LIMIT ?;
            """
        return try database.query(sql, [.int(Int64(limit))]).compactMap(Self.trackRow)
    }

    public func playlistTracks(_ playlist: PlaylistID) throws -> [TrackRow] {
        let sql = """
            SELECT \(Self.trackColumns) \(Self.trackFrom)
            JOIN playlist_track p ON p.track_id = t.id
            WHERE p.playlist_id = ? ORDER BY p.position;
            """
        return try database.query(sql, [.int(playlist.rawValue)]).compactMap(Self.trackRow)
    }

    public func recordPlay(_ track: TrackID, msPlayed: Int64, at time: Int64? = nil) throws {
        try database.run("INSERT INTO playback_history (track_id, played_at, ms_played) VALUES (?, ?, ?);",
                         [.int(track.rawValue), .int(time ?? currentTime()), .int(max(0, msPlayed))])
    }

    // MARK: Search

    /// Prefix search over title, artist, album and album artist; accent- and case-insensitive.
    /// User text is never passed to FTS5 as syntax: each word becomes a quoted prefix term.
    public func search(_ text: String, limit: Int = 50) throws -> [TrackRow] {
        guard let match = Self.ftsQuery(text) else { return [] }
        let sql = """
            SELECT \(Self.trackColumns) \(Self.trackFrom)
            JOIN (SELECT rowid, bm25(track_fts, 10.0, 5.0, 3.0, 3.0) AS rank FROM track_fts WHERE track_fts MATCH ?) m
              ON m.rowid = t.id
            ORDER BY m.rank, t.title COLLATE NOCASE LIMIT ?;
            """
        return try database.query(sql, [.text(match), .int(Int64(limit))]).compactMap(Self.trackRow)
    }

    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(8).compactMap { word -> String? in
            var scalars = String.UnicodeScalarView()
            for scalar in word.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
            }
            let term = String(scalars)  // only letters and digits survive, so no FTS5 syntax can get through
            return term.isEmpty ? nil : "\"\(term)\"*"
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    // MARK: Albums, artists, folders

    public func albums() throws -> [AlbumRow] {
        let sql = """
            SELECT album, coalesce(album_artist, artist, '') AS who, count(*) AS n,
                   coalesce(sum(duration_ms), 0) AS total, max(is_lossless) AS lossless
            FROM track WHERE album IS NOT NULL AND album <> ''
            GROUP BY album COLLATE NOCASE, who COLLATE NOCASE
            ORDER BY album COLLATE NOCASE, who COLLATE NOCASE;
            """
        return try database.query(sql).compactMap { r in
            guard let title = r.text("album") else { return nil }
            return AlbumRow(title: title, artist: r.text("who") ?? "", trackCount: Int(r.int("n") ?? 0),
                            durationMs: r.int("total") ?? 0, hasLossless: r.int("lossless") == 1)
        }
    }

    public func tracks(inAlbum album: String, artist: String) throws -> [TrackRow] {
        try tracks("WHERE t.album = ? COLLATE NOCASE AND coalesce(t.album_artist, t.artist, '') = ? COLLATE NOCASE",
                   [.text(album), .text(artist)], order: "t.disc_no, t.track_no, t.title COLLATE NOCASE")
    }

    public func artists() throws -> [ArtistRow] {
        let sql = """
            SELECT artist, count(*) AS n, count(DISTINCT album) AS albums
            FROM track WHERE artist IS NOT NULL AND artist <> ''
            GROUP BY artist COLLATE NOCASE ORDER BY artist COLLATE NOCASE;
            """
        return try database.query(sql).compactMap { r in
            guard let name = r.text("artist") else { return nil }
            return ArtistRow(name: name, trackCount: Int(r.int("n") ?? 0), albumCount: Int(r.int("albums") ?? 0))
        }
    }

    public func tracks(byArtist artist: String) throws -> [TrackRow] {
        try tracks("WHERE t.artist = ? COLLATE NOCASE OR t.album_artist = ? COLLATE NOCASE", [.text(artist), .text(artist)],
                   order: "t.album COLLATE NOCASE, t.disc_no, t.track_no, t.title COLLATE NOCASE")
    }

    /// Folders that directly contain local tracks, with counts (for the Folders view).
    public func folders() throws -> [FolderRow] {
        let rows = try database.query("SELECT t.path FROM track t JOIN source s ON s.id = t.source_id WHERE s.kind = 'local' AND t.path IS NOT NULL;")
        var counts: [String: Int] = [:]
        for row in rows {
            guard let path = row.text("path") else { continue }
            counts[(path as NSString).deletingLastPathComponent, default: 0] += 1
        }
        return counts.map { FolderRow(path: $0.key, trackCount: $0.value) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public func tracks(inFolder folder: String) throws -> [TrackRow] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return try tracks("WHERE s.kind = 'local' AND substr(t.path, 1, length(?)) = ? AND instr(substr(t.path, length(?) + 1), '/') = 0",
                          [.text(prefix), .text(prefix), .text(prefix)], order: "t.path")
    }
}
