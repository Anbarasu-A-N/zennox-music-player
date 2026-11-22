import Foundation

/// Library operations. Every method works on database rows only: nothing here can read,
/// copy, move or delete an audio file. Favorites and playlists hold track IDs, never audio.
public final class LibraryStore {
    private let db: SQLiteDatabase
    private let now: () -> Int64

    public init(database: SQLiteDatabase,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        self.db = database
        self.now = now
        try Schema.migrate(database)
    }

    // MARK: Sources

    public func addSource(kind: SourceKind, accountID: String = "", displayName: String) throws -> SourceID {
        let rows = try db.query("""
            INSERT INTO source (kind, account_id, display_name, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (kind, account_id) DO UPDATE SET display_name = excluded.display_name
            RETURNING id;
            """, [.text(kind.rawValue), .text(accountID), .text(displayName), .int(now())])
        guard let id = rows.first?.int("id") else { throw LibraryError.notFound }
        return SourceID(rawValue: id)
    }

    // MARK: Tracks

    /// Inserts or refreshes a track identified by (source, externalID). Re-indexing the same
    /// file never creates a second row.
    public func upsertTrack(_ t: TrackInput, in source: SourceID) throws -> TrackID {
        let ts = now()
        let rows = try db.query("""
            INSERT INTO track (source_id, external_id, path, title, artist, album, album_artist,
                track_no, disc_no, duration_ms, codec, sample_rate, bit_depth, channels, is_lossless,
                file_size, mime_type, status, added_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ok', ?, ?)
            ON CONFLICT (source_id, external_id) DO UPDATE SET
                path = excluded.path, title = excluded.title, artist = excluded.artist,
                album = excluded.album, album_artist = excluded.album_artist,
                track_no = excluded.track_no, disc_no = excluded.disc_no,
                duration_ms = excluded.duration_ms, codec = excluded.codec,
                sample_rate = excluded.sample_rate, bit_depth = excluded.bit_depth,
                channels = excluded.channels, is_lossless = excluded.is_lossless,
                file_size = excluded.file_size, mime_type = excluded.mime_type,
                status = 'ok', updated_at = excluded.updated_at
            RETURNING id;
            """, [
                .int(source.rawValue), .text(t.externalID), Self.opt(t.path), .text(t.title),
                Self.opt(t.artist), Self.opt(t.album), Self.opt(t.albumArtist),
                Self.opt(t.trackNumber), Self.opt(t.discNumber), Self.opt(t.durationMs),
                .text(t.codec.rawValue), Self.opt(t.sampleRate), Self.opt(t.bitDepth),
                Self.opt(t.channels), .int(t.codec.isLossless ? 1 : 0), Self.opt(t.fileSize),
                Self.opt(t.mimeType), .int(ts), .int(ts),
            ])
        guard let id = rows.first?.int("id") else { throw LibraryError.notFound }
        return TrackID(rawValue: id)
    }

    public func setStatus(_ status: TrackStatus, for track: TrackID) throws {
        try db.run("UPDATE track SET status = ?, updated_at = ? WHERE id = ?;",
                   [.text(status.rawValue), .int(now()), .int(track.rawValue)])
    }

    public func track(_ id: TrackID) throws -> TrackSummary? {
        guard let row = try db.query(
            "SELECT id, title, codec, is_lossless, status FROM track WHERE id = ?;",
            [.int(id.rawValue)]).first else { return nil }
        return TrackSummary(
            id: id,
            title: row.text("title") ?? "",
            codec: Codec(rawValue: row.text("codec") ?? "") ?? .unknown,
            isLossless: row.int("is_lossless") == 1,
            status: TrackStatus(rawValue: row.text("status") ?? "") ?? .ok)
    }

    public func trackCount() throws -> Int {
        Int(try db.query("SELECT count(*) AS n FROM track;").first?.int("n") ?? 0)
    }

    /// Removes the library entry and its favorites/playlist/history rows (FK cascade).
    /// The audio file itself is untouched; offline cache files are reclaimed by the cache manager.
    public func removeFromLibrary(_ track: TrackID) throws {
        try db.run("DELETE FROM track WHERE id = ?;", [.int(track.rawValue)])
    }

    // MARK: Favorites

    /// Idempotent: favoriting twice keeps one row (PRIMARY KEY on track_id).
    public func setFavorite(_ track: TrackID, _ isFavorite: Bool) throws {
        if isFavorite {
            try db.run("INSERT INTO favorite (track_id, created_at) VALUES (?, ?) ON CONFLICT (track_id) DO NOTHING;",
                       [.int(track.rawValue), .int(now())])
        } else {
            try db.run("DELETE FROM favorite WHERE track_id = ?;", [.int(track.rawValue)])
        }
    }

    public func isFavorite(_ track: TrackID) throws -> Bool {
        try !db.query("SELECT 1 FROM favorite WHERE track_id = ?;", [.int(track.rawValue)]).isEmpty
    }

    public func favorites() throws -> [TrackID] {
        try db.query("SELECT track_id FROM favorite ORDER BY created_at DESC, track_id DESC;")
            .compactMap { $0.int("track_id").map(TrackID.init(rawValue:)) }
    }

    // MARK: Playlists

    public func createPlaylist(named name: String) throws -> PlaylistID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyPlaylistName }
        let ts = now()
        let rows = try db.query(
            "INSERT INTO playlist (name, created_at, updated_at) VALUES (?, ?, ?) RETURNING id;",
            [.text(trimmed), .int(ts), .int(ts)])
        guard let id = rows.first?.int("id") else { throw LibraryError.notFound }
        return PlaylistID(rawValue: id)
    }

    public func append(_ tracks: [TrackID], to playlist: PlaylistID) throws {
        try db.transaction {
            let next = try db.query(
                "SELECT coalesce(max(position) + 1, 0) AS p FROM playlist_track WHERE playlist_id = ?;",
                [.int(playlist.rawValue)]).first?.int("p") ?? 0
            for (offset, track) in tracks.enumerated() {
                try db.run(
                    "INSERT INTO playlist_track (playlist_id, position, track_id, added_at) VALUES (?, ?, ?, ?);",
                    [.int(playlist.rawValue), .int(next + Int64(offset)), .int(track.rawValue), .int(now())])
            }
            try touch(playlist)
        }
    }

    /// Removes one entry and closes the gap in positions.
    public func remove(at position: Int, from playlist: PlaylistID) throws {
        try db.transaction {
            let p = Int64(position), pl = SQLValue.int(playlist.rawValue)
            guard try db.run("DELETE FROM playlist_track WHERE playlist_id = ? AND position = ?;", [pl, .int(p)]) == 1
            else { throw LibraryError.notFound }
            // Two-step shift avoids transient primary-key collisions.
            try db.run("UPDATE playlist_track SET position = -position WHERE playlist_id = ? AND position > ?;", [pl, .int(p)])
            try db.run("UPDATE playlist_track SET position = -position - 1 WHERE playlist_id = ? AND position < 0;", [pl])
            try touch(playlist)
        }
    }

    public func tracks(in playlist: PlaylistID) throws -> [TrackID] {
        try db.query("SELECT track_id FROM playlist_track WHERE playlist_id = ? ORDER BY position;",
                     [.int(playlist.rawValue)])
            .compactMap { $0.int("track_id").map(TrackID.init(rawValue:)) }
    }

    /// Deletes the playlist and its entries; tracks stay in the library.
    public func deletePlaylist(_ playlist: PlaylistID) throws {
        try db.run("DELETE FROM playlist WHERE id = ?;", [.int(playlist.rawValue)])
    }

    private func touch(_ playlist: PlaylistID) throws {
        try db.run("UPDATE playlist SET updated_at = ? WHERE id = ?;", [.int(now()), .int(playlist.rawValue)])
    }

    private static func opt(_ v: String?) -> SQLValue { v.map(SQLValue.text) ?? .null }
    private static func opt(_ v: Int?) -> SQLValue { v.map { .int(Int64($0)) } ?? .null }
    private static func opt(_ v: Int64?) -> SQLValue { v.map(SQLValue.int) ?? .null }
}
