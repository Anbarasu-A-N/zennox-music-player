import XCTest
@testable import ZennoxCore

final class LibraryStoreTests: XCTestCase {
    private var store: LibraryStore!
    private var source: SourceID!

    override func setUpWithError() throws {
        var clock: Int64 = 1_000
        store = try LibraryStore(database: SQLiteDatabase(path: ":memory:"), now: { clock += 1; return clock })
        source = try store.addSource(kind: .local, displayName: "This Mac")
    }

    private func addTrack(_ id: String, codec: Codec = .flac) throws -> TrackID {
        try store.upsertTrack(TrackInput(externalID: id, title: "Song \(id)", codec: codec), in: source)
    }

    func testReindexingSameFileDoesNotDuplicate() throws {
        let a = try addTrack("file-1")
        let b = try addTrack("file-1")
        XCTAssertEqual(a, b)
        XCTAssertEqual(try store.trackCount(), 1)
    }

    func testSameExternalIDInDifferentSourcesIsDistinct() throws {
        let drive = try store.addSource(kind: .googleDrive, accountID: "acct-1", displayName: "Drive")
        let local = try addTrack("x")
        let remote = try store.upsertTrack(TrackInput(externalID: "x", title: "x", codec: .flac), in: drive)
        XCTAssertNotEqual(local, remote)
    }

    func testFavoritingTwiceKeepsOneEntry() throws {
        let t = try addTrack("1")
        try store.setFavorite(t, true)
        try store.setFavorite(t, true)
        XCTAssertEqual(try store.favorites(), [t])
    }

    func testUnfavoriteKeepsTrack() throws {
        let t = try addTrack("1")
        try store.setFavorite(t, true)
        try store.setFavorite(t, false)
        XCTAssertFalse(try store.isFavorite(t))
        XCTAssertNotNil(try store.track(t))
    }

    func testLossyIsNeverLabelledLossless() throws {
        XCTAssertEqual(try store.track(try addTrack("a", codec: .mp3))?.isLossless, false)
        XCTAssertEqual(try store.track(try addTrack("b", codec: .alac))?.isLossless, true)
        XCTAssertEqual(Codec.allCases.filter(\.isLossless), [.flac, .alac, .pcm])
    }

    func testDeletingPlaylistKeepsTracks() throws {
        let t = try addTrack("1")
        let p = try store.createPlaylist(named: "Road trip")
        try store.append([t], to: p)
        try store.deletePlaylist(p)
        XCTAssertNotNil(try store.track(t))
        XCTAssertEqual(try store.trackCount(), 1)
    }

    func testPlaylistReferencesNotCopies() throws {
        let t = try addTrack("1")
        let p1 = try store.createPlaylist(named: "A")
        let p2 = try store.createPlaylist(named: "B")
        try store.append([t, t], to: p1)
        try store.append([t], to: p2)
        XCTAssertEqual(try store.tracks(in: p1), [t, t])
        XCTAssertEqual(try store.trackCount(), 1)
    }

    func testRemoveFromPlaylistClosesGap() throws {
        let ids = try (1...4).map { try addTrack("\($0)") }
        let p = try store.createPlaylist(named: "Mix")
        try store.append(ids, to: p)
        try store.remove(at: 1, from: p)
        XCTAssertEqual(try store.tracks(in: p), [ids[0], ids[2], ids[3]])
        try store.append([ids[1]], to: p)
        XCTAssertEqual(try store.tracks(in: p), [ids[0], ids[2], ids[3], ids[1]])
    }

    func testEmptyPlaylistNameRejected() {
        XCTAssertThrowsError(try store.createPlaylist(named: "   ")) {
            XCTAssertEqual($0 as? LibraryError, .emptyPlaylistName)
        }
    }

    func testRemovingTrackCascadesReferences() throws {
        let t = try addTrack("1")
        let p = try store.createPlaylist(named: "A")
        try store.append([t], to: p)
        try store.setFavorite(t, true)
        try store.removeFromLibrary(t)
        XCTAssertEqual(try store.favorites(), [])
        XCTAssertEqual(try store.tracks(in: p), [])
    }

    func testMissingFileStatusAndRecovery() throws {
        let t = try addTrack("1")
        try store.setStatus(.missing, for: t)
        XCTAssertEqual(try store.track(t)?.status, .missing)
        _ = try addTrack("1")  // file found again on rescan
        XCTAssertEqual(try store.track(t)?.status, .ok)
    }

    func testRefusesNewerSchema() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.execute("PRAGMA user_version = 99;")
        XCTAssertThrowsError(try LibraryStore(database: db)) {
            XCTAssertEqual($0 as? SQLiteError, .schemaNewerThanApp(found: 99, supported: Schema.latestVersion))
        }
    }
}
