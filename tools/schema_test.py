"""Runs the exact v1 schema from Schema.swift against SQLite and checks the library invariants
that the database itself must enforce. Runs anywhere Python 3 is installed: python3 tools/schema_test.py"""
import pathlib, re, sqlite3, sys, unittest

SWIFT = pathlib.Path(__file__).resolve().parents[1] / "Sources/ZennoxCore/Database/Schema.swift"
def migration(n):
    return re.search(r'// BEGIN SQL v%d\s*static let v%d = """\n(.*?)\n\s*"""\s*// END SQL v%d' % (n, n, n), SWIFT.read_text(), re.S).group(1)

SQL = migration(1) + "\n" + migration(2)

class SchemaV1(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:", isolation_level=None)
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.executescript(SQL)
        self.db.execute("INSERT INTO source (kind, display_name, created_at) VALUES ('local','Mac',0)")

    def track(self, ext, codec="flac", lossless=1):
        return self.db.execute(
            "INSERT INTO track (source_id, external_id, title, codec, is_lossless, added_at, updated_at) "
            "VALUES (1, ?, 't', ?, ?, 0, 0) RETURNING id", (ext, codec, lossless)).fetchone()[0]

    def test_unique_track_per_source(self):
        self.track("a")
        with self.assertRaises(sqlite3.IntegrityError): self.track("a")

    def test_lossy_cannot_be_lossless(self):
        for codec in ("mp3", "aac", "vorbis", "opus", "unknown"):
            with self.assertRaises(sqlite3.IntegrityError): self.track("x-" + codec, codec, 1)
        self.track("ok", "alac", 1)

    def test_favorite_unique(self):
        t = self.track("a")
        self.db.execute("INSERT INTO favorite VALUES (?, 0)", (t,))
        with self.assertRaises(sqlite3.IntegrityError): self.db.execute("INSERT INTO favorite VALUES (?, 0)", (t,))

    def test_playlist_delete_keeps_tracks_and_track_delete_cascades(self):
        t = self.track("a")
        self.db.execute("INSERT INTO playlist (name, created_at, updated_at) VALUES ('p', 0, 0)")
        self.db.execute("INSERT INTO playlist_track VALUES (1, 0, ?, 0)", (t,))
        self.db.execute("INSERT INTO favorite VALUES (?, 0)", (t,))
        self.db.execute("DELETE FROM playlist")
        self.assertEqual(self.db.execute("SELECT count(*) FROM track").fetchone()[0], 1)
        self.db.execute("DELETE FROM track")
        self.assertEqual(self.db.execute("SELECT count(*) FROM favorite").fetchone()[0], 0)

    def test_blank_playlist_name_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO playlist (name, created_at, updated_at) VALUES ('  ', 0, 0)")

    def test_unknown_source_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO track (source_id, external_id, title, codec, added_at, updated_at) VALUES (9,'a','t','mp3',0,0)")

    def test_gap_close_two_step_shift(self):
        ids = [self.track(str(i)) for i in range(4)]
        self.db.execute("INSERT INTO playlist (name, created_at, updated_at) VALUES ('p', 0, 0)")
        for pos, t in enumerate(ids): self.db.execute("INSERT INTO playlist_track VALUES (1, ?, ?, 0)", (pos, t))
        self.db.execute("DELETE FROM playlist_track WHERE playlist_id=1 AND position=1")
        self.db.execute("UPDATE playlist_track SET position=-position WHERE playlist_id=1 AND position>1")
        self.db.execute("UPDATE playlist_track SET position=-position-1 WHERE playlist_id=1 AND position<0")
        rows = self.db.execute("SELECT track_id FROM playlist_track ORDER BY position").fetchall()
        self.assertEqual([r[0] for r in rows], [ids[0], ids[2], ids[3]])

class MigrationV1toV2(unittest.TestCase):
    def test_populated_v1_keeps_data_and_gains_roots(self):
        db = sqlite3.connect(":memory:", isolation_level=None)
        db.execute("PRAGMA foreign_keys = ON")
        db.executescript(migration(1))
        db.execute("INSERT INTO source (kind, display_name, created_at) VALUES ('local','Mac',0)")
        db.execute("INSERT INTO track (source_id, external_id, title, codec, is_lossless, added_at, updated_at) VALUES (1,'a','t','flac',1,0,0)")
        db.execute("INSERT INTO favorite VALUES (1, 0)")
        db.executescript(migration(2))
        self.assertEqual(db.execute("SELECT count(*) FROM favorite").fetchone()[0], 1)
        self.assertIsNone(db.execute("SELECT root_id FROM track").fetchone()[0])
        db.execute("INSERT INTO library_root (source_id, kind, display_path, added_at) VALUES (1,'folder','/Music',0)")
        db.execute("UPDATE track SET root_id = 1")
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("INSERT INTO library_root (source_id, kind, display_path, added_at) VALUES (1,'folder','/Music',0)")
        db.execute("DELETE FROM library_root")  # removing a folder removes its library rows (never files)
        self.assertEqual(db.execute("SELECT count(*) FROM track").fetchone()[0], 0)

if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
