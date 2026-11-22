import XCTest
@testable import ZennoxCore

final class MD5Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(MD5.hex([]), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hex(Array("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hex(Array("The quick brown fox jumps over the lazy dog".utf8)), "9e107d9d372bb6826bd81d3542a419d6")
        XCTAssertEqual(MD5.hex([UInt8](repeating: 0x61, count: 1_000)), "cabe45dcc9ae5b66ba86600cca6b8ba8")
    }
}

final class DuplicateDetectorTests: XCTestCase {
    private var store: LibraryStore!
    private var local: SourceID!
    private var drive: SourceID!

    override func setUpWithError() throws {
        store = try LibraryStore(database: SQLiteDatabase(path: ":memory:"))
        local = try store.addSource(kind: .local, displayName: "Mac")
        drive = try store.addSource(kind: .googleDrive, accountID: "0612345", displayName: "me@example.com")
    }

    @discardableResult
    private func add(_ id: String, _ title: String, artist: String?, ms: Int64?, size: Int64?, codec: Codec = .flac,
                     in source: SourceID? = nil, hash: String? = nil) throws -> TrackID {
        let t = try store.upsertTrack(TrackInput(externalID: id, title: title, artist: artist, durationMs: ms, codec: codec, fileSize: size),
                                      in: source ?? local)
        if let hash { try store.setContentHash(t, hash) }
        return t
    }

    func testSameBytesInDriveAndLocalIsAHashMatch() throws {
        let a = try add("l1", "Blue in Green", artist: "Miles Davis", ms: 337_000, size: 40_000_000, hash: "md5:aa")
        let b = try add("d1", "blue in green", artist: "Miles Davis", ms: 337_000, size: 40_000_000, in: drive, hash: "md5:aa")
        XCTAssertEqual(try DuplicateDetector.detect(in: store), 1)
        let group = try XCTUnwrap(try store.duplicateGroups().first)
        XCTAssertEqual(group.reason, .hash)
        XCTAssertEqual(group.tracks.map(\.id), [a, b])
        XCTAssertEqual(Set(group.tracks.map(\.sourceKind)), [.local, .googleDrive])
    }

    func testFLACAndMP3OfSameSongAreAWeakerMatch() throws {
        try add("1", "Café", artist: "Zoé", ms: 200_000, size: 30_000_000, codec: .flac)
        try add("2", "CAFE!", artist: "zoe", ms: 201_200, size: 6_000_000, codec: .mp3)  // accents, case, punctuation differ
        try DuplicateDetector.detect(in: store)
        XCTAssertEqual(try store.duplicateGroups().map(\.reason), [.tagsDuration])
    }

    func testSameSizeAndTagsIsStrongerThanTagsAlone() throws {
        try add("1", "Song", artist: "Band", ms: 100_000, size: 5_000)
        try add("2", "Song", artist: "Band", ms: 100_400, size: 5_000)
        try DuplicateDetector.detect(in: store)
        XCTAssertEqual(try store.duplicateGroups().first?.reason, .sizeDurationTags)
    }

    func testNotDuplicates() throws {
        try add("1", "Intro", artist: "Band", ms: 60_000, size: 1)
        try add("2", "Intro", artist: "Band", ms: 95_000, size: 2)            // live version: 35 s longer
        try add("3", "Track 01", artist: "Band", ms: 60_000, size: 1)        // generic title is not evidence
        try add("4", "Track 01", artist: "Band", ms: 60_000, size: 1)
        try add("5", "Same", artist: nil, ms: 60_000, size: 9)               // no artist: too weak to suggest
        try add("6", "Same", artist: nil, ms: 60_000, size: 9)
        XCTAssertEqual(try DuplicateDetector.detect(in: store), 0)
    }

    func testTransitiveLinksFormOneGroupWithStrongestReason() throws {
        try add("1", "Song", artist: "Band", ms: 100_000, size: 10, hash: "md5:x")
        try add("2", "Song", artist: "Band", ms: 101_500, size: 20)  // tags+duration to 1 and 3
        try add("3", "Other name", artist: "Else", ms: 1, size: 10, hash: "md5:x")  // same bytes as 1
        XCTAssertEqual(try DuplicateDetector.detect(in: store), 1)
        let group = try XCTUnwrap(try store.duplicateGroups().first)
        XCTAssertEqual(group.tracks.count, 3)
        XCTAssertEqual(group.reason, .hash)
    }

    func testDismissalIsRememberedAndNothingIsEverDeleted() throws {
        let a = try add("1", "Song", artist: "Band", ms: 100_000, size: 10)
        let b = try add("2", "Song", artist: "Band", ms: 100_000, size: 10)
        try store.setFavorite(b, true)
        try DuplicateDetector.detect(in: store)
        try store.dismissDuplicates([b, a])
        XCTAssertTrue(try store.duplicateGroups().isEmpty)
        XCTAssertEqual(try DuplicateDetector.detect(in: store), 0)  // stays dismissed
        XCTAssertEqual(try store.trackCount(), 2)
        XCTAssertTrue(try store.isFavorite(b))
    }

    func testMissingTracksAreNotSuggested() throws {
        let a = try add("1", "Song", artist: "Band", ms: 100_000, size: 10)
        try add("2", "Song", artist: "Band", ms: 100_000, size: 10)
        try store.setStatus(.missing, for: a)
        XCTAssertEqual(try DuplicateDetector.detect(in: store), 0)
    }

    func testNormalisation() {
        XCTAssertEqual(DuplicateDetector.normalize("  Beyoncé — Halo (Remix)!! "), "beyonce halo remix")
        XCTAssertEqual(DuplicateDetector.normalize("ＡＢＣ"), "abc")  // full-width letters
        XCTAssertNil(DuplicateDetector.meaningfulTitle("01"))
        XCTAssertNil(DuplicateDetector.meaningfulTitle("Track 7"))
        XCTAssertEqual(DuplicateDetector.meaningfulTitle("7 Rings"), "7 rings")
    }
}

final class LocalContentHasherTests: XCTestCase {
    func testHashesLocalFilesInChunksAndInvalidatesOnChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zennox-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Fixture.cat(Fixture.flac(sampleRate: 44_100, channels: 2, bits: 16, samples: 44_100, comments: ["TITLE=A"], picture: false),
                                [UInt8](repeating: 7, count: 10_000))
        let file = dir.appendingPathComponent("a.flac")
        try Data(bytes).write(to: file)

        let store = try LibraryStore(database: SQLiteDatabase(path: ":memory:"))
        let source = try store.addSource(kind: .local, displayName: "Mac")
        let root = try store.addRoot(source: source, kind: .folder, displayPath: dir.path, accessToken: nil)
        _ = try LocalLibraryScanner(store: store).scan(root: root, path: dir.path, source: source)

        let hasher = LocalContentHasher(store: store, chunkBytes: 4_096)  // forces several chunks
        XCTAssertEqual(try hasher.hashMissing(in: root), 1)
        XCTAssertEqual(try hasher.hashMissing(in: root), 0)  // already hashed
        let id = try XCTUnwrap(try store.knownFiles(in: root).first?.trackID)
        let stored = try store.database.query("SELECT content_hash FROM track WHERE id = ?;", [.int(id.rawValue)]).first?.text("content_hash")
        XCTAssertEqual(stored, "md5:" + MD5.hex(bytes))

        try Data(bytes + [1, 2, 3]).write(to: file)  // file changes → rescan drops the stale hash
        _ = try LocalLibraryScanner(store: store).scan(root: root, path: dir.path, source: source)
        let after = try store.database.query("SELECT content_hash FROM track WHERE id = ?;", [.int(id.rawValue)]).first?.text("content_hash")
        XCTAssertNil(after)
    }
}
