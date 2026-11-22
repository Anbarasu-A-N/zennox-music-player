import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ZennoxCore

/// In-memory stand-in for the Drive v3 endpoints Zennox uses, plus the OAuth token endpoint.
final class FakeDrive: @unchecked Sendable {
    struct File { var name: String; var mime: String; var bytes: [UInt8]; var md5: String; var modified: String; var trashed = false }
    private let lock = NSLock()
    var files: [String: File] = [:]
    /// Status codes to return (in order) before normal handling, per path suffix ("" = any).
    var injected: [(match: String, status: Int, body: String)] = []
    var ignoreRange = false
    private(set) var log: [String] = []

    func handle(_ request: URLRequest) -> (Int, String, Data?) {
        lock.lock(); defer { lock.unlock() }
        let url = request.url!
        let path = url.path
        log.append(path + (url.query.map { "?" + $0 } ?? ""))
        if path == "/token" { return (200, #"{"access_token":"ya29.t\#(log.count)","expires_in":3600}"#, nil) }
        if let i = injected.firstIndex(where: { path.hasSuffix($0.match) }) {
            let hit = injected.remove(at: i)
            return (hit.status, hit.body, nil)
        }
        if path == "/drive/v3/about" {
            return (200, #"{"user":{"permissionId":"0612345","emailAddress":"me@example.com","displayName":"Me"}}"#, nil)
        }
        let id = String(path.dropFirst("/drive/v3/files/".count))
        guard let file = files[id] else { return (404, #"{"error":{"code":404,"errors":[{"reason":"notFound"}]}}"#, nil) }
        if url.query?.contains("alt=media") == true {
            guard !ignoreRange, let range = request.value(forHTTPHeaderField: "Range") else { return (200, "", Data(file.bytes)) }
            let parts = range.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
            let start = parts[0], end = min(parts[1], file.bytes.count - 1)
            if start >= file.bytes.count { return (416, "", nil) }
            return (206, "", Data(file.bytes[start...end]))
        }
        let json = #"{"id":"\#(id)","name":"\#(file.name)","mimeType":"\#(file.mime)","size":"\#(file.bytes.count)","md5Checksum":"\#(file.md5)","modifiedTime":"\#(file.modified)","trashed":\#(file.trashed)}"#
        return (200, json, nil)
    }

    func count(_ fragment: String) -> Int { lock.lock(); defer { lock.unlock() }; return log.filter { $0.contains(fragment) }.count }
}

struct DriveTransport: HTTPTransport {
    let drive: FakeDrive
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body, raw) = drive.handle(request)
        return (raw ?? Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var delays: [UInt64] = []
    func record(_ ns: UInt64) { lock.lock(); delays.append(ns); lock.unlock() }
}

final class DriveTests: XCTestCase {
    typealias F = Fixture
    typealias M = MP4Fixture

    private var fake: FakeDrive!
    private var sleeps: SleepRecorder!
    private var drive: GoogleDriveClient!
    private var store: LibraryStore!
    private var importer: DriveLibraryImporter!

    override func setUpWithError() throws {
        fake = FakeDrive()
        sleeps = SleepRecorder()
        let secure = InMemorySecureStore()
        try secure.write("google.refresh.default", "1//grant")
        let transport = DriveTransport(drive: fake)
        let tokens = GoogleTokenManager(config: GoogleOAuthConfig(clientID: "cid", redirectURI: "http://127.0.0.1/cb"),
                                        store: secure, transport: transport)
        let recorder = sleeps!
        drive = GoogleDriveClient(tokens: tokens, transport: transport, maxAttempts: 4,
                                  sleep: { recorder.record($0) }, jitter: { 0 })
        store = try LibraryStore(database: SQLiteDatabase(path: ":memory:"))
        importer = DriveLibraryImporter(store: store, drive: drive)
    }

    private func flacBytes(_ title: String) -> [UInt8] {
        F.flac(sampleRate: 96_000, channels: 2, bits: 24, samples: 96_000 * 200, comments: ["TITLE=" + title], picture: false)
    }

    /// ALAC M4A with moov after a 300 KB mdat, so the first 256 KB contain no codec info.
    private func alacMoovAtEnd() -> [UInt8] {
        let entry = M.sampleEntry("alac", channels: 2, rate: 0, children: M.alacConfig(bitDepth: 24, channels: 2, rate: 192_000))
        let moov: [UInt8] = M.atom("moov", M.track(timescale: 192_000, duration: 192_000 * 60, entry: entry))
        return F.cat(M.ftyp, M.atom("mdat", F.zeros(300_000)), moov)
    }

    func testAboutGivesStableSourcePerAccount() async throws {
        let user = try await drive.about()
        XCTAssertEqual(user.permissionID, "0612345")
        let a = try importer.ensureSource(for: user)
        let b = try importer.ensureSource(for: user)
        XCTAssertEqual(a, b)
    }

    func testImportPickedFilesMixed() async throws {
        fake.files = [
            "flac1": .init(name: "Track.flac", mime: "application/octet-stream", bytes: flacBytes("Hi-Res"), md5: "aa", modified: "2026-11-01T10:00:00.000Z"),
            "alac1": .init(name: "Song.m4a", mime: "audio/mp4", bytes: alacMoovAtEnd(), md5: "bb", modified: "2026-11-01T10:00:00Z"),
            "doc1": .init(name: "Notes.pdf", mime: "application/pdf", bytes: F.ascii("%PDF"), md5: "cc", modified: "2026-11-01T10:00:00Z"),
            "fake1": .init(name: "fake.mp3", mime: "audio/mpeg", bytes: F.ascii("<html>"), md5: "dd", modified: "2026-11-01T10:00:00Z"),
            "bin1": .init(name: "old.flac", mime: "audio/flac", bytes: flacBytes("x"), md5: "ee", modified: "2026-11-01T10:00:00Z", trashed: true),
        ]
        let source = try importer.ensureSource(for: try await drive.about())
        let report = try await importer.importPicked(["flac1", "alac1", "doc1", "fake1", "bin1", "gone1", "../etc", "flac1"], into: source)
        XCTAssertEqual(report, DriveImportReport(added: 2, updated: 0, skipped: 2, unavailable: 2, invalidIDs: 1))

        let flac = try XCTUnwrap(try store.trackID(source: source, externalID: "flac1"))
        XCTAssertEqual(try store.track(flac)?.codec, .flac)
        XCTAssertEqual(try store.track(flac)?.title, "Hi-Res")
        let alac = try XCTUnwrap(try store.trackID(source: source, externalID: "alac1"))
        XCTAssertEqual(try store.track(alac)?.codec, .alac)
        XCTAssertEqual(try store.track(alac)?.isLossless, true)
        XCTAssertEqual(fake.count("/files/../etc"), 0)  // invalid ID never sent
        // Bounded reads only: the 300 KB ALAC file was read as prefix + tail, never fully.
        XCTAssertEqual(fake.count("alac1?alt=media"), 2)

        let again = try await importer.importPicked(["flac1"], into: source)
        XCTAssertEqual(again.updated, 1)
        XCTAssertEqual(try store.trackCount(), 2)
    }

    func testRateLimitBackoffThenSuccess() async throws {
        fake.files = ["f": .init(name: "a.flac", mime: "audio/flac", bytes: flacBytes("A"), md5: "1", modified: "2026-11-01T10:00:00Z")]
        fake.injected = [
            ("/files/f", 403, #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#),
            ("/files/f", 429, #"{"error":{"code":429}}"#),
        ]
        let file = try await drive.file("f")
        XCTAssertEqual(file.name, "a.flac")
        XCTAssertEqual(sleeps.delays, [1_000_000_000, 2_000_000_000])
    }

    func testPersistentServerErrorGivesUpAfterMaxAttempts() async throws {
        fake.injected = Array(repeating: (match: "/files/f", status: 503, body: ""), count: 10)
        do { _ = try await drive.file("f"); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? DriveError, .server(status: 503))
        }
        XCTAssertEqual(sleeps.delays.count, 3)  // 4 attempts → 3 waits
    }

    func testOther403IsNotRetried() async throws {
        fake.injected = [("/files/f", 403, #"{"error":{"errors":[{"reason":"insufficientFilePermissions"}]}}"#)]
        do { _ = try await drive.file("f"); XCTFail() } catch {
            XCTAssertEqual(error as? DriveError, .forbidden(reason: "insufficientFilePermissions"))
        }
        XCTAssertTrue(sleeps.delays.isEmpty)
    }

    func testExpiredAccessTokenRefreshesOnceOn401() async throws {
        fake.files = ["f": .init(name: "a.flac", mime: "audio/flac", bytes: flacBytes("A"), md5: "1", modified: "2026-11-01T10:00:00Z")]
        fake.injected = [("/files/f", 401, "")]
        _ = try await drive.file("f")
        XCTAssertEqual(fake.count("/token"), 2)  // initial + refresh after 401
        XCTAssertTrue(sleeps.delays.isEmpty)

        fake.injected = [("/files/f", 401, ""), ("/files/f", 401, "")]
        do { _ = try await drive.file("f"); XCTFail() } catch { XCTAssertEqual(error as? DriveError, .unauthorized) }
    }

    func testReadSlicesWhenServerIgnoresRange() async throws {
        let bytes: [UInt8] = (0..<100).map { UInt8($0) }
        fake.files = ["f": .init(name: "a.flac", mime: "audio/flac", bytes: bytes, md5: "1", modified: "2026-11-01T10:00:00Z")]
        let ranged = try await drive.read("f", offset: 10, length: 5)
        XCTAssertEqual(ranged, [10, 11, 12, 13, 14])
        fake.ignoreRange = true
        let sliced = try await drive.read("f", offset: 10, length: 5)
        XCTAssertEqual(sliced, [10, 11, 12, 13, 14])
        fake.ignoreRange = false
        let past = try await drive.read("f", offset: 500, length: 5)
        XCTAssertEqual(past, [])
    }

    func testRefreshDetectsTrashedRevokedAndChangedFiles() async throws {
        fake.files = [
            "keep": .init(name: "k.flac", mime: "audio/flac", bytes: flacBytes("Keep"), md5: "1", modified: "2026-11-01T10:00:00Z"),
            "edit": .init(name: "e.flac", mime: "audio/flac", bytes: flacBytes("Old"), md5: "2", modified: "2026-11-01T10:00:00Z"),
            "bin": .init(name: "b.flac", mime: "audio/flac", bytes: flacBytes("Bin"), md5: "3", modified: "2026-11-01T10:00:00Z"),
            "gone": .init(name: "g.flac", mime: "audio/flac", bytes: flacBytes("Gone"), md5: "4", modified: "2026-11-01T10:00:00Z"),
        ]
        let source = try importer.ensureSource(for: try await drive.about())
        _ = try await importer.importPicked(["keep", "edit", "bin", "gone"], into: source)
        let keep = try XCTUnwrap(try store.trackID(source: source, externalID: "keep"))
        try store.setFavorite(keep, true)

        fake.files["edit"]?.bytes = flacBytes("New")
        fake.files["edit"]?.md5 = "2b"
        fake.files["edit"]?.modified = "2026-11-20T10:00:00Z"
        fake.files["bin"]?.trashed = true
        fake.files["gone"] = nil

        let report = try await importer.refresh(source)
        XCTAssertEqual(report, DriveRefreshReport(unchanged: 1, updated: 1, missing: 1, inaccessible: 1))
        let edit = try XCTUnwrap(try store.trackID(source: source, externalID: "edit"))
        XCTAssertEqual(try store.track(edit)?.title, "New")
        XCTAssertEqual(try store.track(XCTUnwrap(try store.trackID(source: source, externalID: "gone")))?.status, .inaccessible)
        XCTAssertTrue(try store.isFavorite(keep))
        XCTAssertEqual(try store.trackCount(), 4)  // nothing removed automatically
    }

    func testFileIDValidationAndAudioDetection() {
        XCTAssertTrue(GoogleDriveClient.isValidFileID("1AbC-d_9"))
        for bad in ["", "../x", "a/b", "a?b", "a b", "ä", String(repeating: "a", count: 201)] {
            XCTAssertFalse(GoogleDriveClient.isValidFileID(bad), bad)
        }
        func file(_ name: String, _ mime: String) -> DriveFile {
            DriveFile(id: "x", name: name, mimeType: mime, size: 1, md5: nil, modifiedTime: nil, trashed: false)
        }
        XCTAssertTrue(DriveLibraryImporter.looksLikeAudio(file("a.opus", "application/octet-stream")))
        XCTAssertTrue(DriveLibraryImporter.looksLikeAudio(file("noext", "audio/flac")))
        XCTAssertFalse(DriveLibraryImporter.looksLikeAudio(file("Music", "application/vnd.google-apps.folder")))
        XCTAssertFalse(DriveLibraryImporter.looksLikeAudio(file("a.pdf", "application/pdf")))
        XCTAssertEqual(DriveLibraryImporter.milliseconds("2026-11-01T10:00:00.500Z"), 1_793_527_200_500)
        XCTAssertEqual(DriveLibraryImporter.milliseconds("2026-11-01T10:00:00Z"), 1_793_527_200_000)
    }
}
