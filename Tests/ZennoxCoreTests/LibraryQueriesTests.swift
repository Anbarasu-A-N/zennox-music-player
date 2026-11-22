import XCTest
@testable import ZennoxCore

final class LibraryQueriesTests: XCTestCase {
    private var store: LibraryStore!
    private var local: SourceID!
    private var clock: Int64 = 0

    override func setUpWithError() throws {
        clock = 1_000
        store = try LibraryStore(database: SQLiteDatabase(path: ":memory:"), now: { [unowned self] in self.clock += 1; return self.clock })
        local = try store.addSource(kind: .local, displayName: "Mac")
    }

    @discardableResult
    private func add(_ id: String, _ title: String, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                     track: Int? = nil, disc: Int? = nil, ms: Int64? = nil, codec: Codec = .mp3, path: String? = nil) throws -> TrackID {
        try store.upsertTrack(TrackInput(externalID: id, path: path, title: title, artist: artist, album: album,
                                         albumArtist: albumArtist, trackNumber: track, discNumber: disc,
                                         durationMs: ms, codec: codec), in: local)
    }

    func testSearchIsPrefixAccentAndCaseInsensitiveAndRanksTitleFirst() throws {
        let cafe = try add("1", "Café del Mar", artist: "Energy 52")
        let byArtist = try add("2", "Sunrise", artist: "Cafe Tacvba")
        try add("3", "Unrelated", artist: "Nobody")
        XCTAssertEqual(try store.search("CAFE").map(\.id), [cafe, byArtist])  // title match outranks artist match
        XCTAssertEqual(try store.search("caf mar").map(\.id), [cafe])          // all words must match
        XCTAssertEqual(try store.search("  ").count, 0)
    }

    func testSearchNeverPassesUserSyntaxToFTS() throws {
        try add("1", "AND OR NOT", artist: "x")
        for hostile in ["\"", "*", "a\" OR \"b", "NEAR(", "title:x", "-", "^", "'); DROP TABLE track; --"] {
            XCTAssertNoThrow(try store.search(hostile), hostile)
        }
        XCTAssertEqual(try store.trackCount(), 1)
        XCTAssertEqual(LibraryStore.ftsQuery("don't stop!"), "\"dont\"* \"stop\"*")
    }

    func testSearchStaysInSyncWithEditsAndDeletes() throws {
        let t = try add("1", "Old Title")
        try add("1", "New Title")  // re-index (upsert) changes the title
        XCTAssertEqual(try store.search("old").count, 0)
        XCTAssertEqual(try store.search("new").map(\.id), [t])
        try store.removeFromLibrary(t)
        XCTAssertEqual(try store.search("new").count, 0)
    }

    func testSortOrders() throws {
        let b = try add("1", "beta", artist: "Zed", ms: 100)
        let a = try add("2", "Alpha", artist: "amy", ms: 300)
        let c = try add("3", "Gamma", ms: 200)  // no artist sorts last
        XCTAssertEqual(try store.allTracks(sort: .title).map(\.id), [a, b, c])
        XCTAssertEqual(try store.allTracks(sort: .artist).map(\.id), [a, b, c])
        XCTAssertEqual(try store.allTracks(sort: .duration).map(\.id), [a, c, b])
        XCTAssertEqual(try store.allTracks(sort: .recentlyAdded).map(\.id), [c, a, b])
        XCTAssertEqual(try store.allTracks(sort: .title, limit: 1, offset: 1).map(\.id), [b])
    }

    func testAlbumsGroupByAlbumArtistAndOrderTracks() throws {
        try add("1", "Two", artist: "Guest", album: "Hits", albumArtist: "Various", track: 2, ms: 1_000, codec: .flac)
        try add("2", "One", artist: "Star", album: "hits", albumArtist: "Various", track: 1, ms: 2_000)
        try add("3", "Solo", artist: "Star", album: "Hits", track: 1)  // same title, different artist → separate album
        let albums = try store.albums()
        XCTAssertEqual(albums.count, 2)
        let various = try XCTUnwrap(albums.first { $0.artist == "Various" })
        XCTAssertEqual(various.trackCount, 2)
        XCTAssertEqual(various.durationMs, 3_000)
        XCTAssertTrue(various.hasLossless)
        XCTAssertEqual(try store.tracks(inAlbum: "Hits", artist: "Various").map(\.title), ["One", "Two"])
    }

    func testArtists() throws {
        try add("1", "a", artist: "Star", album: "X")
        try add("2", "b", artist: "star", album: "Y")
        try add("3", "c", artist: "Other")
        let artists = try store.artists()
        XCTAssertEqual(artists.map(\.trackCount), [1, 2])
        XCTAssertEqual(artists.last?.albumCount, 2)
        XCTAssertEqual(try store.tracks(byArtist: "STAR").count, 2)
    }

    func testRecentlyPlayedListsEachTrackOnceNewestFirst() throws {
        let a = try add("1", "A")
        let b = try add("2", "B")
        try store.recordPlay(a, msPlayed: 30_000, at: 10)
        try store.recordPlay(b, msPlayed: 30_000, at: 20)
        try store.recordPlay(a, msPlayed: 30_000, at: 30)
        XCTAssertEqual(try store.recentlyPlayed().map(\.id), [a, b])
    }

    func testFavoritesAndPlaylistRowsCarryFlags() throws {
        let a = try add("1", "A", codec: .flac)
        let b = try add("2", "B")
        try store.setFavorite(b, true)
        XCTAssertEqual(try store.favoriteTracks().map(\.id), [b])
        let p = try store.createPlaylist(named: "Mix")
        try store.append([b, a], to: p)
        let rows = try store.playlistTracks(p)
        XCTAssertEqual(rows.map(\.id), [b, a])
        XCTAssertEqual(rows.map(\.isFavorite), [true, false])
        XCTAssertEqual(rows.last?.isLossless, true)
        XCTAssertEqual(rows.first?.sourceKind, .local)
    }

    func testFoldersAndFolderContents() throws {
        try add("1", "a", path: "/Music/Jazz/a.flac")
        try add("2", "b", path: "/Music/Jazz/b.flac")
        try add("3", "c", path: "/Music/Jazz/Live/c.flac")
        let folders = try store.folders()
        XCTAssertEqual(folders, [FolderRow(path: "/Music/Jazz", trackCount: 2), FolderRow(path: "/Music/Jazz/Live", trackCount: 1)])
        XCTAssertEqual(try store.tracks(inFolder: "/Music/Jazz").map(\.title), ["a", "b"])  // not the Live subfolder
    }

    func testV2DatabaseGainsSearchOnMigration() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.transaction {
            try db.execute(Schema.v1)
            try db.execute(Schema.v2)
            try db.execute("PRAGMA user_version = 2;")
        }
        try db.run("INSERT INTO source (kind, display_name, created_at) VALUES ('local', 'Mac', 0);")
        try db.run("INSERT INTO track (source_id, external_id, title, codec, added_at, updated_at) VALUES (1, 'x', 'Before Search', 'mp3', 0, 0);")
        let migrated = try LibraryStore(database: db)
        XCTAssertEqual(try migrated.search("before").map(\.title), ["Before Search"])
    }
}
