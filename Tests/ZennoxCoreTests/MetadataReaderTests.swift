import XCTest
@testable import ZennoxCore

/// Fixtures are built in code from the format specs so no binary files live in the repo.
/// Every concatenation goes through `cat(...)`, whose `[UInt8]...` parameter gives literals a
/// fixed type; long `a + [1] + b` chains are too slow for Swift's type checker.
enum Fixture {
    static func cat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }
    static func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }
    static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
    static func byte(_ v: Int) -> UInt8 { UInt8(truncatingIfNeeded: v) }
    static func be32(_ v: Int) -> [UInt8] { [byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)] }
    static func be24(_ v: Int) -> [UInt8] { [byte(v >> 16), byte(v >> 8), byte(v)] }
    static func be16(_ v: Int) -> [UInt8] { [byte(v >> 8), byte(v)] }
    static func le32(_ v: Int) -> [UInt8] { [byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24)] }
    static func le16(_ v: Int) -> [UInt8] { [byte(v), byte(v >> 8)] }
    static func syncsafe(_ v: Int) -> [UInt8] {
        [byte((v >> 21) & 0x7F), byte((v >> 14) & 0x7F), byte((v >> 7) & 0x7F), byte(v & 0x7F)]
    }

    static func flac(sampleRate: Int, channels: Int, bits: Int, samples: Int64, comments: [String], picture: Bool) -> [UInt8] {
        let sampleHigh: Int = Int((samples >> 32) & 0x0F)
        let sampleLow: Int = Int(samples & 0xFFFF_FFFF)
        let rateLow: Int = (sampleRate & 0x0F) << 4
        let channelBits: Int = (channels - 1) << 1
        let bitsHigh: Int = (bits - 1) >> 4
        let bitsLow: Int = ((bits - 1) & 0x0F) << 4
        let packed: [UInt8] = [
            byte(sampleRate >> 12),
            byte(sampleRate >> 4),
            byte(rateLow | channelBits | bitsHigh),
            byte(bitsLow | sampleHigh),
        ]
        let info: [UInt8] = cat(zeros(10), packed, be32(sampleLow), zeros(16))  // last 16 = MD5

        var vc: [UInt8] = cat(le32(4), ascii("test"), le32(comments.count))
        for c in comments {
            vc.append(contentsOf: le32(c.utf8.count))
            vc.append(contentsOf: ascii(c))
        }

        let commentHeader: UInt8 = picture ? 0x04 : 0x84  // 0x80 = last block
        var out: [UInt8] = cat(ascii("fLaC"), [0x00], be24(info.count), info)
        out.append(contentsOf: cat([commentHeader], be24(vc.count), vc))
        if picture {
            out.append(contentsOf: cat([0x86], be24(100_000), zeros(64)))  // truncated picture block
        }
        return out
    }

    static func id3Frame(_ id: String, _ body: [UInt8]) -> [UInt8] { cat(ascii(id), be32(body.count), [0, 0], body) }

    static func id3v23(_ frames: [UInt8]) -> [UInt8] { cat(ascii("ID3"), [3, 0, 0], syncsafe(frames.count), frames) }

    static func oggPage(_ payload: [UInt8]) -> [UInt8] {
        cat(ascii("OggS"), [0, 2], zeros(20), [1, byte(payload.count)], payload)
    }

    static func wav(format: Int, channels: Int, rate: Int, byteRate: Int, align: Int, bits: Int, dataSize: Int?) -> [UInt8] {
        let fmt: [UInt8] = cat(le16(format), le16(channels), le32(rate), le32(byteRate), le16(align), le16(bits))
        var out: [UInt8] = cat(ascii("RIFF"), le32(0), ascii("WAVE"), ascii("fmt "), le32(fmt.count), fmt)
        if let dataSize { out.append(contentsOf: cat(ascii("data"), le32(dataSize))) }
        return out
    }

    static func aiff(channels: Int, frames: Int, bits: Int, rate80: [UInt8]) -> [UInt8] {
        let comm: [UInt8] = cat(be16(channels), be32(frames), be16(bits), rate80)
        return cat(ascii("FORM"), be32(0), ascii("AIFF"), ascii("COMM"), be32(comm.count), comm)
    }

    /// MPEG-1 Layer III, 128 kbps, 44.1 kHz, joint stereo.
    static let mpegHeader: [UInt8] = [0xFF, 0xFB, 0x90, 0x40]
}

final class MetadataReaderTests: XCTestCase {
    typealias F = Fixture

    func testFLACStreamInfoAndComments() {
        let comments: [String] = ["TITLE=Blue in Green", "artist=Miles Davis", "TRACKNUMBER=3/5", "ALBUMARTIST=Miles Davis"]
        let bytes = F.flac(sampleRate: 96_000, channels: 2, bits: 24, samples: 96_000 * 180, comments: comments, picture: true)
        let m = MetadataReader.read(bytes)
        XCTAssertEqual(m.container, Container.flac)
        XCTAssertEqual(m.codec, Codec.flac)
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
        let m = MetadataReader.read(F.flac(sampleRate: 192_000, channels: 6, bits: 32, samples: 192_000, comments: [], picture: false))
        XCTAssertEqual(m.sampleRate, 192_000)
        XCTAssertEqual(m.channels, 6)
        XCTAssertEqual(m.bitDepth, 32)
        XCTAssertEqual(m.durationMs, 1_000)
    }

    func testID3v23TagsWithUTF16AndLatin1() {
        var utf16Title: [UInt8] = [1, 0xFF, 0xFE]  // encoding 1 + little-endian BOM
        for unit in "Café".utf16 { utf16Title.append(contentsOf: [F.byte(Int(unit)), F.byte(Int(unit) >> 8)]) }
        utf16Title.append(contentsOf: [0, 0])
        let apic: [UInt8] = F.cat([0], F.ascii("image/jpeg"), [0, 3, 0, 0xFF, 0xD8])
        let frames: [UInt8] = F.cat(
            F.id3Frame("TIT2", utf16Title),
            F.id3Frame("TPE1", F.cat([0], F.ascii("Nina Simone"))),
            F.id3Frame("TRCK", F.cat([3], F.ascii("7/12"))),
            F.id3Frame("APIC", apic))
        let tag = F.id3v23(frames)
        let bytes: [UInt8] = F.cat(tag, F.mpegHeader, F.zeros(400))
        let fileSize = Int64(tag.count) + 1_600_000  // 1.6 MB of audio after the tag
        let m = MetadataReader.read(bytes, fileSize: fileSize)
        XCTAssertEqual(m.codec, Codec.mp3)
        XCTAssertFalse(m.isLossless)
        XCTAssertEqual(m.title, "Café")
        XCTAssertEqual(m.artist, "Nina Simone")
        XCTAssertEqual(m.trackNumber, 7)
        XCTAssertTrue(m.hasArtwork)
        XCTAssertEqual(m.sampleRate, 44_100)
        XCTAssertEqual(m.channels, 2)
        XCTAssertNil(m.bitDepth)
        XCTAssertTrue(m.durationIsEstimate)
        XCTAssertEqual(m.durationMs, 100_000)  // 1_600_000 bytes * 8 / 128 kbps
    }

    func testMP3XingFrameCountGivesExactDuration() {
        let bytes: [UInt8] = F.cat(F.mpegHeader, F.zeros(32), F.ascii("Xing"), F.be32(1), F.be32(1_000), F.zeros(200))
        let m = MetadataReader.read(bytes, fileSize: 5_000_000)
        let expected: Int64 = 1_000 * 1_152 * 1_000 / 44_100
        XCTAssertEqual(m.durationMs, expected)
        XCTAssertFalse(m.durationIsEstimate)
    }

    func testWAVPCM() {
        let m = MetadataReader.read(F.wav(format: 1, channels: 2, rate: 44_100, byteRate: 176_400, align: 4, bits: 16, dataSize: 1_764_000))
        XCTAssertEqual(m.codec, Codec.pcm)
        XCTAssertTrue(m.isLossless)
        XCTAssertEqual(m.sampleRate, 44_100)
        XCTAssertEqual(m.bitDepth, 16)
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.durationMs, 10_000)
    }

    func testWAVContainingMP3IsNotLossless() {
        let m = MetadataReader.read(F.wav(format: 0x55, channels: 2, rate: 44_100, byteRate: 16_000, align: 1, bits: 0, dataSize: nil))
        XCTAssertEqual(m.codec, Codec.unknown)
        XCTAssertFalse(m.isLossless)
    }

    func testAIFF() {
        let rate44100: [UInt8] = [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]
        let m = MetadataReader.read(F.aiff(channels: 2, frames: 441_000, bits: 16, rate80: rate44100))
        XCTAssertEqual(m.codec, Codec.pcm)
        XCTAssertEqual(m.sampleRate, 44_100)
        XCTAssertEqual(m.bitDepth, 16)
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.durationMs, 10_000)
    }

    func testAIFFTinySampleRateDoesNotDivideByZero() {
        let half: [UInt8] = [0x3F, 0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0]  // 0.5 Hz
        XCTAssertNil(MetadataReader.read(F.aiff(channels: 1, frames: 10, bits: 16, rate80: half)).durationMs)
    }

    func testOggOpus() {
        let head: [UInt8] = F.cat(F.ascii("OpusHead"), [1, 2], F.le16(312), F.le32(44_100), [0, 0, 0])
        let opus = MetadataReader.read(F.oggPage(head))
        XCTAssertEqual(opus.codec, Codec.opus)
        XCTAssertEqual(opus.channels, 2)
        XCTAssertEqual(opus.sampleRate, 48_000)
        XCTAssertFalse(opus.isLossless)
    }

    func testOggVorbis() {
        let ident: [UInt8] = F.cat([1], F.ascii("vorbis"), F.le32(0), [2], F.le32(44_100), F.zeros(14))
        let vorbis = MetadataReader.read(F.oggPage(ident))
        XCTAssertEqual(vorbis.codec, Codec.vorbis)
        XCTAssertEqual(vorbis.channels, 2)
        XCTAssertEqual(vorbis.sampleRate, 44_100)
    }

    func testFLACWithLeadingID3() {
        let flac = F.flac(sampleRate: 44_100, channels: 2, bits: 16, samples: 44_100, comments: [], picture: false)
        let m = MetadataReader.read(F.cat(F.id3v23([]), flac))
        XCTAssertEqual(m.codec, Codec.flac)
        XCTAssertEqual(m.durationMs, 1_000)
    }

    func testUnknownAndMP4Container() {
        XCTAssertEqual(MetadataReader.read(F.ascii("<html>not audio</html>")).container, Container.unknown)
        XCTAssertEqual(MetadataReader.read([]).container, Container.unknown)
        let mp4 = MetadataReader.read(F.cat(F.be32(20), F.ascii("ftypM4A "), F.zeros(8)))
        XCTAssertEqual(mp4.container, Container.mp4)
        XCTAssertFalse(mp4.isLossless)  // not claimed until atoms are parsed (L2b)
    }

    func testTrackInputFromMetadataFallsBackToFileName() {
        var m = AudioMetadata()
        m.codec = .alac
        m.sampleRate = 48_000
        let input = TrackInput(externalID: "drive-id", fileName: "01 - Intro.m4a", metadata: m, fileSize: 42)
        XCTAssertEqual(input.title, "01 - Intro")
        XCTAssertEqual(input.codec, Codec.alac)
        XCTAssertEqual(input.sampleRate, 48_000)
        XCTAssertEqual(input.fileSize, 42)
    }

    /// Malformed input must never crash: every truncation and thousands of random mutations.
    func testFuzzNeverTraps() {
        let seeds: [[UInt8]] = [
            F.flac(sampleRate: 48_000, channels: 2, bits: 16, samples: 4_800, comments: ["TITLE=x"], picture: true),
            F.cat(F.id3v23(F.id3Frame("TIT2", F.cat([3], F.ascii("x")))), F.mpegHeader, F.zeros(64)),
            F.wav(format: 1, channels: 2, rate: 44_100, byteRate: 176_400, align: 4, bits: 16, dataSize: 100),
            F.cat(F.ascii("FORM"), F.be32(0), F.ascii("AIFCCOMM"), F.be32(22), [UInt8](repeating: 0x7F, count: 22)),
            F.oggPage(F.cat(F.ascii("OpusHead"), [1, 2], F.zeros(9))),
        ]
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: rng >> 33)
        }
        for seed in seeds {
            for length in 0...seed.count {
                _ = MetadataReader.read(Array(seed.prefix(length)), fileSize: Int64(length))
            }
            for _ in 0..<2_000 {
                var mutated = seed
                let flips = 1 + next() % 8
                for _ in 0..<flips {
                    mutated[next() % mutated.count] = F.byte(next())
                }
                _ = MetadataReader.read(mutated, fileSize: Int64(next() % 10_000_000))
            }
        }
    }
}
