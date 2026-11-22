import Foundation

/// Versioned, forward-only migrations. tools/schema_test.py extracts the SQL between the
/// BEGIN/END markers and runs it with Python's sqlite3, so keep the markers intact.
public enum Schema {
    public static let latestVersion = 3

    static let migrations: [(version: Int, sql: String)] = [(1, v1), (2, v2), (3, v3)]

    // BEGIN SQL v1
    static let v1 = """
    CREATE TABLE source (
        id            INTEGER PRIMARY KEY,
        kind          TEXT    NOT NULL CHECK (kind IN ('local', 'gdrive')),
        account_id    TEXT    NOT NULL DEFAULT '',
        display_name  TEXT    NOT NULL,
        created_at    INTEGER NOT NULL,
        UNIQUE (kind, account_id)
    );

    CREATE TABLE track (
        id             INTEGER PRIMARY KEY,
        source_id      INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
        external_id    TEXT    NOT NULL,
        path           TEXT,
        title          TEXT    NOT NULL,
        artist         TEXT,
        album          TEXT,
        album_artist   TEXT,
        track_no       INTEGER,
        disc_no        INTEGER,
        duration_ms    INTEGER CHECK (duration_ms IS NULL OR duration_ms >= 0),
        codec          TEXT    NOT NULL CHECK (codec IN ('flac','alac','pcm','mp3','aac','vorbis','opus','unknown')),
        sample_rate    INTEGER,
        bit_depth      INTEGER,
        channels       INTEGER,
        is_lossless    INTEGER NOT NULL DEFAULT 0
                       CHECK (is_lossless IN (0, 1) AND (is_lossless = 0 OR codec IN ('flac','alac','pcm'))),
        file_size      INTEGER,
        content_hash   TEXT,
        mime_type      TEXT,
        status         TEXT    NOT NULL DEFAULT 'ok' CHECK (status IN ('ok','missing','inaccessible')),
        added_at       INTEGER NOT NULL,
        updated_at     INTEGER NOT NULL,
        UNIQUE (source_id, external_id)
    );
    CREATE INDEX track_album  ON track(album_artist, album, disc_no, track_no);
    CREATE INDEX track_artist ON track(artist);
    CREATE INDEX track_added  ON track(added_at DESC);
    CREATE INDEX track_dupe   ON track(file_size, duration_ms);

    CREATE TABLE favorite (
        track_id    INTEGER PRIMARY KEY REFERENCES track(id) ON DELETE CASCADE,
        created_at  INTEGER NOT NULL
    );

    CREATE TABLE playlist (
        id          INTEGER PRIMARY KEY,
        name        TEXT    NOT NULL CHECK (length(trim(name)) > 0),
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
    );

    CREATE TABLE playlist_track (
        playlist_id INTEGER NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
        position    INTEGER NOT NULL,
        track_id    INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
        added_at    INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, position)
    );
    CREATE INDEX playlist_track_track ON playlist_track(track_id);

    CREATE TABLE playback_history (
        id          INTEGER PRIMARY KEY,
        track_id    INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
        played_at   INTEGER NOT NULL,
        ms_played   INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX playback_history_recent ON playback_history(played_at DESC);

    CREATE TABLE offline_download (
        track_id    INTEGER PRIMARY KEY REFERENCES track(id) ON DELETE CASCADE,
        local_path  TEXT,
        bytes_total INTEGER,
        bytes_done  INTEGER NOT NULL DEFAULT 0,
        state       TEXT    NOT NULL CHECK (state IN ('queued','downloading','complete','failed')),
        updated_at  INTEGER NOT NULL
    );

    CREATE TABLE duplicate_candidate (
        group_id    INTEGER NOT NULL,
        track_id    INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
        reason      TEXT    NOT NULL CHECK (reason IN ('hash','size_duration_tags','tags_duration')),
        PRIMARY KEY (group_id, track_id)
    );
    """
    // END SQL v1

    // v2: local library roots (folders/files the user added) and file identity for rename/move detection.
    // BEGIN SQL v2
    static let v2 = """
    CREATE TABLE library_root (
        id            INTEGER PRIMARY KEY,
        source_id     INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
        kind          TEXT    NOT NULL CHECK (kind IN ('folder', 'file')),
        display_path  TEXT    NOT NULL,
        access_token  TEXT,
        status        TEXT    NOT NULL DEFAULT 'ok' CHECK (status IN ('ok', 'inaccessible')),
        added_at      INTEGER NOT NULL,
        last_scan_at  INTEGER,
        UNIQUE (source_id, display_path)
    );
    ALTER TABLE track ADD COLUMN root_id INTEGER REFERENCES library_root(id) ON DELETE CASCADE;
    ALTER TABLE track ADD COLUMN file_identity TEXT;
    ALTER TABLE track ADD COLUMN file_modified INTEGER;
    CREATE INDEX track_root ON track(root_id);
    """
    // END SQL v2

    // v3: full-text search over title/artist/album/album artist (external-content FTS5 kept in sync by
    // triggers, accent- and case-insensitive), plus indexes for library views.
    // BEGIN SQL v3
    static let v3 = """
    CREATE VIRTUAL TABLE track_fts USING fts5(
        title, artist, album, album_artist,
        content = 'track', content_rowid = 'id',
        tokenize = 'unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER track_fts_insert AFTER INSERT ON track BEGIN
        INSERT INTO track_fts (rowid, title, artist, album, album_artist)
        VALUES (new.id, new.title, new.artist, new.album, new.album_artist);
    END;
    CREATE TRIGGER track_fts_delete AFTER DELETE ON track BEGIN
        INSERT INTO track_fts (track_fts, rowid, title, artist, album, album_artist)
        VALUES ('delete', old.id, old.title, old.artist, old.album, old.album_artist);
    END;
    CREATE TRIGGER track_fts_update AFTER UPDATE OF title, artist, album, album_artist ON track BEGIN
        INSERT INTO track_fts (track_fts, rowid, title, artist, album, album_artist)
        VALUES ('delete', old.id, old.title, old.artist, old.album, old.album_artist);
        INSERT INTO track_fts (rowid, title, artist, album, album_artist)
        VALUES (new.id, new.title, new.artist, new.album, new.album_artist);
    END;
    INSERT INTO track_fts (track_fts) VALUES ('rebuild');
    CREATE INDEX playback_history_track ON playback_history(track_id, played_at DESC);
    CREATE INDEX track_title ON track(title COLLATE NOCASE);
    """
    // END SQL v3

    /// Applies pending migrations, each in its own transaction. Refuses to open a database
    /// written by a newer app version rather than corrupting it.
    public static func migrate(_ db: SQLiteDatabase) throws {
        let current = try db.userVersion()
        guard current <= latestVersion else {
            throw SQLiteError.schemaNewerThanApp(found: current, supported: latestVersion)
        }
        for migration in migrations where migration.version > current {
            try db.transaction {
                try db.execute(migration.sql)
                try db.execute("PRAGMA user_version = \(migration.version);")
            }
        }
    }
}
