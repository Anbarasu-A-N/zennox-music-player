import XCTest
@testable import ZennoxCore

/// Fixtures are built in code from the format specs so no binary files live in the repo.
enum Fixture {
    static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
    static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func be24(_ v: Int) -> [UInt8] { Array(be32(v).dropFirst()) }
    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { Array(be32(v).reversed()) }
    static func le16(_ v: Int) -> [UInt8] { Array(be16(v).reversed()) }
    static func syncsafe(_ v: Int) -> [UInt8] { [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)] }

    static func flac(sampleRate: Int, channels: Int, bits: Int, samples: Int64, comments: [String], picture: Bool) -> [UInt8] {
        var info = [UInt8](repeating: 0, count: 10)
        info.append(UInt8((sampleRate >> 12) & 0xFF))
        info.append(UInt8((sampleRate >> 4) & 0xFF))
        info.append(UInt8(((sampleRate & 0x0F) << 4) | ((channels - 1) << 1) | ((bits - 1) >> 4)))
        info.append(UInt8((((bits - 1) & 0x0F) << 4) | Int((samples >> 32) & 0x0F)))
        info += be32(Int(samples & 0xFFFF_FFFF))
        info += [UInt8](repeating: 0, count: 16)  // MD5

        var vc = le32(4) + ascii("test") + le32(comments.count)
        for c in comments { vc += le32(c.utf8.count) + ascii(c) }

        var out = ascii("fLaC")
        out += [0x00] + be24(info.count) + info
        out += [picture ? 0x04 : 0x84] + be24(vc.count) + vc
        if picture { out += [0x86] + be24(100_000) + [UInt8](repeating: 0, count: 64) }  // truncated picture
        return out
    }

    static func id3Frame(_ id: String, _ body: [UInt8]) -> [UInt8] { ascii(id) + be32(body.count) + [0, 0] + body }

    static func id3v23(_ frames: [UInt8]) -> [UInt8] { ascii("ID3") + [3, 0, 0] + syncsafe(frames.count) + frames }

    /// MPEG-1 Layer III, 128 kbps, 44.1 kHz, joint stereo.
    static let mpegHeader: [UInt8] = [0xFF, 0xFB, 0x90, 0x40]
}

final class MetadataReaderTests: XCTestCase {
    func testFLACStreamInfoAndComments() {
        let bytes = Fixture.flac(sampleRate: 96_000, channels: 2, bits: 24, samples: 96_000 * 180,
                                 comments: ["TITLE=Blue in Green", "artist=Miles Davis", "TRACKNUMBER=3/5", "ALBUMARTIST=Miles Davis"],
                                 picture: true)
        let m = MetadataReader.read(bytes)
        XCTAssertEqual(m.container, .flac)
        XCTAssertEqual(m.codec, .flac)
        XCTAssertTrue(m.isLossless)
        XCTAssertEqual(m.sampleRate, 96_000)
        XCTAssertEqual(m.bitDepth, 24)
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.durationMs, 180_000)
        XCTAssertEqual(m.title, "Blue in Green")
        XCTAssertEqual(m.artist, "Miles Davis")
        XCTAssertEqual(m.trackNumber, 3)
        XCTAssertTrue(m.hasArtwork)
    }

    func testFLACHighSampleRateFields() {
        let m = MetadataReader.read(Fixture.flac(sampleRate: 192_000, channels: 6, bits: 32, samples: 192_000, comments: [], picture: false))
        XCTAssertEqual([m.sampleRate, m.channels, m.bitDepth], [192_000, 6, 32])
        XCTAssertEqual(m.durationMs, 1_000)
    }

    func testID3v23TagsWithUTF16AndLatin1() {
        let utf16Title: [UInt8] = [1, 0xFF, 0xFE] + Array("Café".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
        let frames = Fixture.id3Frame("TIT2", utf16Title)
            + Fixture.id3Frame("TPE1", [0] + Fixture.ascii("Nina Simone"))
            + Fixture.id3Frame("TRCK", [3] + Fixture.ascii("7/12"))
            + Fixture.id3Frame("APIC", [0] + Fixture.ascii("image/jpeg") + [0, 3, 0, 0xFF, 0xD8])
        let bytes = Fixture.id3v23(frames) + Fixture.mpegHeader + [UInt8](repeating: 0, count: 400)
        let m = MetadataReader.read(bytes, fileSize: Int64(bytes.count - 4 - 400) + 1_600_000)
        XCTAssertEqual(m.codec, .mp3)
        XCTAssertFalse(m.isLossless)
        XCTAssertEqual(m.title, "Café")
        XCTAssertEqual(m.artist, "Nina Simone")
        XCTAssertEqual(m.trackNumber, 7)
        XCTAssertTrue(m.hasArtwork)
        XCTAssertEqual(m.sampleRate, 44_100)
        XCTAssertEqual(m.channels, 2)
        XCTAssertNil(m.bitDepth)
        XCTAssertTrue(m.durationIsEstimate)
        // 1_600_000 audio bytes * 8 / 128 kbps = 100 s
        XCTAssertEqual(Double(m.durationMs ?? 0), 100_000, accuracy: 100)
    }

    func testMP3XingFrameCountGivesExactDuration() {
        var frame = Fixture.mpegHeader + [UInt8](repeating: 0, count: 32)  // MPEG-1 stereo side info
        frame += Fixture.ascii("Xing") + Fixture.be32(1) + Fixture.be32(1_000)
        let m = MetadataReader.read(frame + [UInt8](repeating: 0, count: 200), fileSize: 5_000_000)
        XCTAssertEqual(m.durationMs, 1_000 * 1152 * 1000 / 44_100)
        XCTAssertFalse(m.durationIsEstimate)
    }

    func testWAVPCM() {
        let fmt = Fixture.le16(1) + Fixture.le16(2) + Fixture.le32(44_100) + Fixture.le32(176_400) + Fixture.le16(4) + Fixture.le16(16)
        let bytes = Fixture.ascii("RIFF") + Fixture.le32(0) + Fixture.ascii("WAVE")
            + Fixture.ascii("fmt ") + Fixture.le32(fmt.count) + fmt
            + Fixture.ascii("data") + Fixture.le32(1_764_000)
        let m = MetadataReader.read(bytes)
        XCTAssertEqual(m.codec, .pcm)
        XCTAssertTrue(m.isLossless)
        XCTAssertEqual([m.sampleRate, m.bitDepth, m.channels], [44_100, 16, 2])
        XCTAssertEqual(m.durationMs, 10_000)
    }

    func testWAVContainingMP3IsNotLossless() {
        let fmt = Fixture.le16(0x55) + Fixture.le16(2) + Fixture.le32(44_100) + Fixture.le32(16_000) + Fixture.le16(1) + Fixture.le16(0)
        let bytes = Fixture.ascii("RIFF") + Fixture.le32(0) + Fixture.ascii("WAVE") + Fixture.ascii("fmt ") + Fixture.le32(fmt.count) + fmt
        let m = MetadataReader.read(bytes)
        XCTAssertEqual(m.codec, .unknown)
        XCTAssertFalse(m.isLossless)
    }

    func testAIFF() {
        let rate44100: [UInt8] = [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]
        let comm = Fixture.be16(2) + Fixture.be32(441_000) + Fixture.be16(16) + rate44100
        let bytes = Fixture.ascii("FORM") + Fixture.be32(0) + Fixture.ascii("AIFF") + Fixture.ascii("COMM") + Fixture.be32(comm.count) + comm
        let m = MetadataReader.read(bytes)
        XCTAssertEqual(m.codec, .pcm)
        XCTAssertEqual([m.sampleRate, m.bitDepth, m.channels], [44_100, 16, 2])
        XCTAssertEqual(m.durationMs, 10_000)
    }

    private func oggPage(_ payload: [UInt8]) -> [UInt8] {
        Fixture.ascii("OggS") + [0, 2] + [UInt8](repeating: 0, count: 20) + [1, UInt8(payload.count)] + payload
    }

    func testOggOpusAndVorbis() {
        let opus = MetadataReader.read(oggPage(Fixture.ascii("OpusHead") + [1, 2] + Fixture.le16(312) + Fixture.le32(44_100) + [0, 0, 0]))
        XCTAssertEqual(opus.codec, .opus)
        XCTAssertEqual(opus.channels, 2)
        XCTAssertEqual(opus.sampleRate, 48_000)
        XCTAssertFalse(opus.isLossless)

        let vorbis = MetadataReader.read(oggPage([1] + Fixture.ascii("vorbis") + Fixture.le32(0) + [2] + Fixture.le32(44_100) + [UInt8](repeating: 0, count: 14)))
        XCTAssertEqual(vorbis.codec, .vorbis)
        XCTAssertEqual(vorbis.sampleRate, 44_100)
    }

    func testFLACWithLeadingID3() {
        let flac = Fixture.flac(sampleRate: 44_100, channels: 2, bits: 16, samples: 44_100, comments: [], picture: false)
        let m = MetadataReader.read(Fixture.id3v23([]) + flac)
        XCTAssertEqual(m.codec, .flac)
        XCTAssertEqual(m.durationMs, 1_000)
    }

    func testUnknownAndMP4Container() {
        XCTAssertEqual(MetadataReader.read(Fixture.ascii("<html>not audio</html>")).container, .unknown)
        XCTAssertEqual(MetadataReader.read([]).container, .unknown)
        let mp4 = MetadataReader.read(Fixture.be32(20) + Fixture.ascii("ftypM4A ") + [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(mp4.container, .mp4)
        XCTAssertFalse(mp4.isLossless)  // not claimed until atoms are parsed
    }

    func testTrackInputFromMetadataFallsBackToFileName() {
        var m = AudioMetadata()
        m.codec = .alac
        m.sampleRate = 48_000
        let input = TrackInput(externalID: "drive-id", fileName: "01 - Intro.m4a", metadata: m, fileSize: 42)
        XCTAssertEqual(input.title, "01 - Intro")
        XCTAssertEqual(input.codec, .alac)
        XCTAssertEqual(input.sampleRate, 48_000)
        XCTAssertEqual(input.fileSize, 42)
    }

    func testAIFFTinySampleRateDoesNotDivideByZero() {
        let tiny: [UInt8] = [0x3F, 0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0]  // 0.5 Hz
        let comm = Fixture.be16(1) + Fixture.be32(10) + Fixture.be16(16) + tiny
        let bytes = Fixture.ascii("FORM") + Fixture.be32(0) + Fixture.ascii("AIFF") + Fixture.ascii("COMM") + Fixture.be32(comm.count) + comm
        XCTAssertNil(MetadataReader.read(bytes).durationMs)
    }

    /// Malformed input must never crash: every truncation and thousands of random mutations.
    func testFuzzNeverTraps() {
        let seeds: [[UInt8]] = [
            Fixture.flac(sampleRate: 48_000, channels: 2, bits: 16, samples: 4800, comments: ["TITLE=x"], picture: true),
            Fixture.id3v23(Fixture.id3Frame("TIT2", [3] + Fixture.ascii("x"))) + Fixture.mpegHeader + [UInt8](repeating: 0, count: 64),
            Fixture.ascii("RIFF") + Fixture.le32(0) + Fixture.ascii("WAVEfmt ") + Fixture.le32(16) + [UInt8](repeating: 1, count: 16),
            Fixture.ascii("FORM") + Fixture.be32(0) + Fixture.ascii("AIFCCOMM") + Fixture.be32(22) + [UInt8](repeating: 0x7F, count: 22),
            oggPage(Fixture.ascii("OpusHead") + [1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ]
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: rng >> 33) }
        for seed in seeds {
            for length in 0...seed.count { _ = MetadataReader.read(Array(seed.prefix(length)), fileSize: Int64(length)) }
            for _ in 0..<2_000 {
                var mutated = seed
                for _ in 0..<(1 + next() % 8) { mutated[next() % mutated.count] = UInt8(truncatingIfNeeded: next()) }
                _ = MetadataReader.read(mutated, fileSize: Int64(next() % 10_000_000))
            }
        }
    }
}
