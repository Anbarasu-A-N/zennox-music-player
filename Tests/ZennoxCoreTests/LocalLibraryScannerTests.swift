import XCTest
@testable import ZennoxCore

/// Runs against the real filesystem in a temporary folder (macOS and Linux in CI).
final class LocalLibraryScannerTests: XCTestCase {
    private var dir: URL!
    private var store: LibraryStore!
    private var source: SourceID!
    private var root: RootID!
    private var scanner: LocalLibraryScanner!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zennox-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try LibraryStore(database: SQLiteDatabase(path: ":memory:"))
        source = try store.addSource(kind: .local, displayName: "This Mac")
        root = try store.addRoot(source: source, kind: .folder, displayPath: dir.path, accessToken: nil)
        scanner = LocalLibraryScanner(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func flac(seconds: Int, title: String) -> [UInt8] {
        Fixture.flac(sampleRate: 44_100, channels: 2, bits: 16, samples: Int64(44_100 * seconds),
                     comments: ["TITLE=" + title], picture: false)
    }

    @discardableResult
    private func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    private func scan() throws -> ScanReport { try scanner.scan(root: root, path: dir.path, source: source) }

    func testFirstScanAddsAudioAndIgnoresOtherFiles() throws {
        try write("a.flac", flac(seconds: 10, title: "A"))
        try write("Album/b.flac", flac(seconds: 20, title: "B"))
        try write("notes.txt", Fixture.ascii("hello"))
        try write("fake.mp3", Fixture.ascii("<html>not audio</html>"))
        try write(".hidden.flac", flac(seconds: 1, title: "hidden"))

        let r = try scan()
        XCTAssertEqual(r.added, 2)
        XCTAssertEqual(r.skipped, 1)  // fake.mp3
        XCTAssertEqual(try store.trackCount(), 2)
    }

    func testRescanWithoutChangesReadsNothingNew() throws {
        try write("a.flac", flac(seconds: 10, title: "A"))
        _ = try scan()
        let r = try scan()
        XCTAssertEqual(r.unchanged, 1)
        XCTAssertEqual(r.added + r.updated + r.moved + r.missing, 0)
    }

    func testRenameAndMoveKeepTrackAndFavorite() throws {
        let url = try write("a.flac", flac(seconds: 10, title: "A"))
        _ = try scan()
        let id = try XCTUnwrap(try store.knownFiles(in: root).first?.trackID)
        try store.setFavorite(id, true)

        let moved = dir.appendingPathComponent("Moved/renamed.flac")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: moved)

        let r = try scan()
        XCTAssertEqual(r.moved, 1)
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(try store.trackCount(), 1)
        XCTAssertTrue(try store.isFavorite(id))
        XCTAssertEqual(try store.knownFiles(in: root).first?.path, LocalFileSystem.canonical(moved.path))
    }

    func testDeletedFileBecomesMissingThenRecovers() throws {
        let bytes = flac(seconds: 10, title: "A")
        let url = try write("a.flac", bytes)
        _ = try scan()
        let id = try XCTUnwrap(try store.knownFiles(in: root).first?.trackID)
        try store.setFavorite(id, true)

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try scan().missing, 1)
        XCTAssertEqual(try store.track(id)?.status, .missing)
        XCTAssertTrue(try store.isFavorite(id))  // nothing is deleted from the library automatically

        try write("a.flac", bytes)
        _ = try scan()
        XCTAssertEqual(try store.track(id)?.status, .ok)
        XCTAssertEqual(try store.trackCount(), 1)
    }

    func testChangedContentIsReread() throws {
        try write("a.flac", flac(seconds: 10, title: "Old"))
        _ = try scan()
        try write("a.flac", flac(seconds: 30, title: "New") + Fixture.zeros(10))  // different size
        let r = try scan()
        XCTAssertEqual(r.updated, 1)
        let id = try XCTUnwrap(try store.knownFiles(in: root).first?.trackID)
        XCTAssertEqual(try store.track(id)?.title, "New")
    }

    func testUnreachableRootMarksTracksInaccessibleNotDeleted() throws {
        try write("a.flac", flac(seconds: 10, title: "A"))
        _ = try scan()
        try FileManager.default.removeItem(at: dir)
        let r = try scan()
        XCTAssertTrue(r.rootInaccessible)
        XCTAssertEqual(try store.trackCount(), 1)
        XCTAssertEqual(try store.knownFiles(in: root).first?.status, .inaccessible)
        XCTAssertEqual(try store.roots(in: source).first?.status, .inaccessible)
    }

    func testRemovingRootRemovesLibraryEntriesButNotFiles() throws {
        let url = try write("a.flac", flac(seconds: 10, title: "A"))
        _ = try scan()
        try store.removeRoot(root)
        XCTAssertEqual(try store.trackCount(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testReaddingSameFolderKeepsRoot() throws {
        let again = try store.addRoot(source: source, kind: .folder, displayPath: dir.path, accessToken: "new-grant")
        XCTAssertEqual(again, root)
        XCTAssertEqual(try store.roots(in: source).first?.accessToken, "new-grant")
    }

    /// Scanning through a symlinked path (macOS: /var → /private/var) stores canonical paths, so a
    /// rescan through either spelling matches the same tracks.
    func testSymlinkedRootStoresCanonicalPaths() throws {
        try write("a.flac", flac(seconds: 10, title: "A"))
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("zennox-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link) }

        XCTAssertEqual(try scanner.scan(root: root, path: link.path, source: source).added, 1)
        let stored = try XCTUnwrap(try store.knownFiles(in: root).first?.path)
        XCTAssertEqual(stored, LocalFileSystem.canonical(dir.appendingPathComponent("a.flac").path))

        let viaRealPath = try scanner.scan(root: root, path: dir.path, source: source)
        XCTAssertEqual(viaRealPath.unchanged, 1)
        XCTAssertEqual(viaRealPath.added + viaRealPath.moved + viaRealPath.missing, 0)
    }

    func testLargeFolderBatches() throws {
        for i in 0..<450 { try write("bulk/\(i).flac", flac(seconds: 1, title: "T\(i)")) }
        XCTAssertEqual(try scan().added, 450)
        XCTAssertEqual(try scan().unchanged, 450)
    }
}

final class SchemaMigrationTests: XCTestCase {
    func testV1DatabaseMigratesToV2KeepingData() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.transaction { try db.execute(Schema.v1); try db.execute("PRAGMA user_version = 1;") }
        try db.run("INSERT INTO source (kind, display_name, created_at) VALUES ('local', 'Mac', 0);")
        try db.run("INSERT INTO track (source_id, external_id, title, codec, is_lossless, added_at, updated_at) VALUES (1, 'a', 't', 'flac', 1, 0, 0);")
        try db.run("INSERT INTO favorite VALUES (1, 0);")

        let store = try LibraryStore(database: db)
        XCTAssertEqual(try db.userVersion(), Schema.latestVersion)
        XCTAssertEqual(try store.favorites(), [TrackID(rawValue: 1)])
    }

    func testNestedTransactionRollsBackOnlyInnerPart() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.execute("CREATE TABLE t (v INTEGER);")
        try db.transaction {
            try db.run("INSERT INTO t VALUES (1);")
            _ = try? db.transaction { () throws -> Void in
                try db.run("INSERT INTO t VALUES (2);")
                throw LibraryError.notFound
            }
        }
        XCTAssertEqual(try db.query("SELECT v FROM t;").compactMap { $0.int("v") }, [1])
    }
}

/// Two folder entries that turn out to be the same folder (macOS bookmarks follow renames), and
/// folders nested inside each other.
final class RootReconciliationTests: XCTestCase {
    private var dir: URL!
    private var store: LibraryStore!
    private var source: SourceID!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zennox-roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        let song = Fixture.flac(sampleRate: 44_100, channels: 2, bits: 16, samples: 44_100 * 200, comments: ["TITLE=Radhimaa"], picture: false)
        try Data(song).write(to: dir.appendingPathComponent("a.flac"))
        try Data(song + [1]).write(to: dir.appendingPathComponent("Sub/b.flac"))
        store = try LibraryStore(database: SQLiteDatabase(path: ":memory:"))
        source = try store.addSource(kind: .local, displayName: "Mac")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testSameFolderAddedTwiceMergesAndKeepsFavoritesAndPlaylists() throws {
        let scanner = LocalLibraryScanner(store: store)
        let first = try store.addRoot(source: source, kind: .folder, displayPath: "/old/name", accessToken: "t1")
        let second = try store.addRoot(source: source, kind: .folder, displayPath: dir.path, accessToken: "t2")
        // Both entries resolve to the same real folder (what happened after the rename).
        _ = try scanner.scan(root: first, path: dir.path, source: source)
        let duplicateScan = try scanner.scan(root: second, path: dir.path, source: source)
        XCTAssertEqual(duplicateScan.overlapping, 2)  // the scanner already refuses to list them twice
        XCTAssertEqual(try store.trackCount(), 2)

        // Simulate the pre-fix state: second root owning its own copies, one of them favourited.
        let favourite = try XCTUnwrap(try store.knownFiles(in: first).first?.trackID)
        try store.setFavorite(favourite, true)
        let playlist = try store.createPlaylist(named: "Mix")
        try store.append([favourite], to: playlist)

        try store.mergeRoot(second, into: first)
        XCTAssertEqual(try store.roots(in: source).map(\.id), [first])
        XCTAssertEqual(try store.trackCount(), 2)
        XCTAssertTrue(try store.isFavorite(favourite))
        XCTAssertEqual(try store.tracks(in: playlist), [favourite])
        try store.updateRoot(first, displayPath: dir.path, accessToken: nil)
        XCTAssertEqual(try store.roots(in: source).first?.displayPath, dir.path)
        XCTAssertEqual(try store.roots(in: source).first?.accessToken, "t1")  // nil keeps the existing grant
    }

    func testMergingDuplicateTracksCarriesEverythingOver() throws {
        let rootA = try store.addRoot(source: source, kind: .folder, displayPath: "/a", accessToken: nil)
        let rootB = try store.addRoot(source: source, kind: .folder, displayPath: "/b", accessToken: nil)
        let keep = try store.upsertLocalTrack(TrackInput(externalID: "k", title: "Song", codec: .mp3), source: source, root: rootA, identity: "1:42", modified: 1)
        let drop = try store.upsertLocalTrack(TrackInput(externalID: "d", title: "Song", codec: .mp3), source: source, root: rootB, identity: "1:42", modified: 1)
        try store.setFavorite(drop, true)
        try store.recordPlay(drop, msPlayed: 1_000, at: 5)
        let playlist = try store.createPlaylist(named: "P")
        try store.append([drop, drop], to: playlist)

        try store.mergeRoot(rootB, into: rootA)
        XCTAssertEqual(try store.trackCount(), 1)
        XCTAssertTrue(try store.isFavorite(keep))
        XCTAssertEqual(try store.tracks(in: playlist), [keep, keep])
        XCTAssertEqual(try store.recentlyPlayed().map(\.id), [keep])
    }

    func testNestedFoldersNeverListAFileTwice() throws {
        let scanner = LocalLibraryScanner(store: store)
        let parent = try store.addRoot(source: source, kind: .folder, displayPath: dir.path, accessToken: nil)
        let child = try store.addRoot(source: source, kind: .folder, displayPath: dir.appendingPathComponent("Sub").path, accessToken: nil)
        XCTAssertEqual(try scanner.scan(root: parent, path: dir.path, source: source).added, 2)
        let nested = try scanner.scan(root: child, path: dir.appendingPathComponent("Sub").path, source: source)
        XCTAssertEqual(nested.added, 0)
        XCTAssertEqual(nested.overlapping, 1)
        XCTAssertEqual(try store.trackCount(), 2)
    }

    func testFileMovedBetweenAddedFoldersKeepsItsFavorite() throws {
        let scanner = LocalLibraryScanner(store: store)
        let other = dir.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let rootA = try store.addRoot(source: source, kind: .folder, displayPath: dir.appendingPathComponent("Sub").path, accessToken: nil)
        let rootB = try store.addRoot(source: source, kind: .folder, displayPath: other.path, accessToken: nil)
        _ = try scanner.scan(root: rootA, path: dir.appendingPathComponent("Sub").path, source: source)
        let song = try XCTUnwrap(try store.knownFiles(in: rootA).first?.trackID)
        try store.setFavorite(song, true)

        try FileManager.default.moveItem(at: dir.appendingPathComponent("Sub/b.flac"), to: other.appendingPathComponent("b.flac"))
        XCTAssertEqual(try scanner.scan(root: rootA, path: dir.appendingPathComponent("Sub").path, source: source).missing, 1)
        XCTAssertEqual(try scanner.scan(root: rootB, path: other.path, source: source).moved, 1)
        XCTAssertEqual(try store.knownFiles(in: rootB).map(\.trackID), [song])
        XCTAssertTrue(try store.isFavorite(song))
        XCTAssertEqual(try store.trackCount(), 1)
    }
}
