import XCTest
@testable import ZennoxCore

/// MP4 and Ogg fixtures, built from the specs with typed helpers (see Fixture in MetadataReaderTests).
enum MP4Fixture {
    typealias F = Fixture

    /// Four-character code; "©" (U+00A9) becomes the single byte 0xA9 as in real files.
    static func code(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }
    static func atom(_ type: String, _ body: [UInt8]) -> [UInt8] { F.cat(F.be32(8 + body.count), code(type), body) }
    static func fullAtom(_ type: String, _ body: [UInt8]) -> [UInt8] { atom(type, F.cat(F.zeros(4), body)) }

    static func mdhd(timescale: Int, duration: Int) -> [UInt8] {
        fullAtom("mdhd", F.cat(F.zeros(8), F.be32(timescale), F.be32(duration), F.zeros(4)))
    }

    static func hdlr(_ handler: String) -> [UInt8] { fullAtom("hdlr", F.cat(F.zeros(4), code(handler), F.zeros(13))) }

    /// Audio sample entry (version 0) with optional child boxes.
    static func sampleEntry(_ format: String, channels: Int, rate: Int, children: [UInt8]) -> [UInt8] {
        let rateFixed: Int = (rate & 0xFFFF) << 16
        let fields: [UInt8] = F.cat(F.zeros(6), F.be16(1), F.zeros(8), F.be16(channels), F.be16(16), F.zeros(4), F.be32(rateFixed))
        return atom(format, F.cat(fields, children))
    }

    static func alacConfig(bitDepth: Int, channels: Int, rate: Int) -> [UInt8] {
        let cfg: [UInt8] = F.cat(F.be32(4096), [0, F.byte(bitDepth), 40, 10, 14, F.byte(channels)], F.be16(255), F.zeros(8), F.be32(rate))
        return fullAtom("alac", cfg)
    }

    static func track(timescale: Int, duration: Int, entry: [UInt8]) -> [UInt8] {
        let stsd: [UInt8] = fullAtom("stsd", F.cat(F.be32(1), entry))
        let minf: [UInt8] = atom("minf", atom("stbl", stsd))
        let mdia: [UInt8] = atom("mdia", F.cat(mdhd(timescale: timescale, duration: duration), hdlr("soun"), minf))
        return atom("trak", mdia)
    }

    static func textItem(_ key: String, _ text: String) -> [UInt8] {
        atom(key, atom("data", F.cat(F.be32(1), F.zeros(4), F.ascii(text))))
    }

    static func tags() -> [UInt8] {
        let trkn: [UInt8] = atom("trkn", atom("data", F.cat(F.zeros(8), F.zeros(2), F.be16(4), F.be16(9), F.zeros(2))))
        let covr: [UInt8] = atom("covr", atom("data", F.cat(F.be32(13), F.zeros(4), [0xFF, 0xD8, 0xFF])))
        let ilst: [UInt8] = atom("ilst", F.cat(textItem("\u{A9}nam", "So What"), textItem("\u{A9}ART", "Miles Davis"),
                                              textItem("aART", "Miles Davis"), trkn, covr))
        let meta: [UInt8] = fullAtom("meta", F.cat(hdlr("mdir"), ilst))
        return atom("udta", meta)
    }

    static let ftyp: [UInt8] = atom("ftyp", F.cat(F.ascii("M4A "), F.zeros(4), F.ascii("M4A isom")))
}

enum OggFixture {
    typealias F = Fixture

    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

    static func page(lacing: [UInt8], payload: [UInt8], granule: UInt64 = 0, headerType: UInt8 = 0) -> [UInt8] {
        F.cat(F.ascii("OggS"), [0, headerType], le64(granule), F.zeros(12), [F.byte(lacing.count)], lacing, payload)
    }

    static func comments(vendor: String, _ entries: [String]) -> [UInt8] {
        var out: [UInt8] = F.cat(F.le32(vendor.utf8.count), F.ascii(vendor), F.le32(entries.count))
        for e in entries { out.append(contentsOf: F.cat(F.le32(e.utf8.count), F.ascii(e))) }
        return out
    }
}

final class MP4OggMetadataTests: XCTestCase {
    typealias F = Fixture
    typealias M = MP4Fixture
    typealias O = OggFixture

    func testM4AWithALACIsLosslessWithTrueSpecs() {
        let entry = M.sampleEntry("alac", channels: 2, rate: 0, children: M.alacConfig(bitDepth: 24, channels: 2, rate: 96_000))
        let moov: [UInt8] = M.atom("moov", F.cat(M.track(timescale: 96_000, duration: 96_000 * 545, entry: entry), M.tags()))
        let file: [UInt8] = F.cat(M.ftyp, moov, M.atom("mdat", F.zeros(32)))
        let m = MetadataReader.read(file)
        XCTAssertEqual(m.container, Container.mp4)
        XCTAssertEqual(m.codec, Codec.alac)
        XCTAssertTrue(m.isLossless)
        XCTAssertEqual(m.sampleRate, 96_000)  // from ALAC config, not the 16-bit sample-entry field
        XCTAssertEqual(m.bitDepth, 24)
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.durationMs, 545_000)
        XCTAssertEqual(m.title, "So What")
        XCTAssertEqual(m.artist, "Miles Davis")
        XCTAssertEqual(m.albumArtist, "Miles Davis")
        XCTAssertEqual(m.trackNumber, 4)
        XCTAssertTrue(m.hasArtwork)
        XCTAssertFalse(m.needsTailBytes)
    }

    func testM4AWithAACIsLossyAndMoovAtEndNeedsTail() {
        let entry = M.sampleEntry("mp4a", channels: 2, rate: 44_100, children: [])
        let moov: [UInt8] = M.atom("moov", M.track(timescale: 44_100, duration: 44_100 * 200, entry: entry))
        // mdat header claims 50 MB, so the prefix ends inside the audio and moov is not reachable.
        let mdatHeader: [UInt8] = F.cat(F.be32(50_000_000), F.ascii("mdat"), F.zeros(1_000))
        let prefix: [UInt8] = F.cat(M.ftyp, mdatHeader)

        let first = MetadataReader.read(prefix)
        XCTAssertTrue(first.needsTailBytes)
        XCTAssertEqual(first.codec, Codec.unknown)
        XCTAssertFalse(first.isLossless)

        let tail: [UInt8] = F.cat(F.zeros(500), moov)
        let second = MetadataReader.read(prefix, tail: tail)
        XCTAssertEqual(second.codec, Codec.aac)
        XCTAssertFalse(second.isLossless)
        XCTAssertNil(second.bitDepth)
        XCTAssertEqual(second.sampleRate, 44_100)
        XCTAssertEqual(second.durationMs, 200_000)
        XCTAssertFalse(second.needsTailBytes)
    }

    func testOggOpusCommentsAndDurationFromTail() {
        let head: [UInt8] = F.cat(F.ascii("OpusHead"), [1, 2], F.le16(312), F.le32(44_100), [0, 0, 0])
        let tags: [UInt8] = F.cat(F.ascii("OpusTags"), O.comments(vendor: "libopus", ["TITLE=Night Drive", "ARTIST=Zennox"]))
        let prefix: [UInt8] = F.cat(O.page(lacing: [F.byte(head.count)], payload: head, headerType: 2),
                                   O.page(lacing: [F.byte(tags.count)], payload: tags))
        let noTail = MetadataReader.read(prefix)
        XCTAssertEqual(noTail.codec, Codec.opus)
        XCTAssertEqual(noTail.title, "Night Drive")
        XCTAssertEqual(noTail.artist, "Zennox")
        XCTAssertNil(noTail.durationMs)
        XCTAssertTrue(noTail.needsTailBytes)

        let tail: [UInt8] = F.cat(F.zeros(100), O.page(lacing: [1], payload: [0], granule: 48_000 * 60 + 312, headerType: 4))
        XCTAssertEqual(MetadataReader.read(prefix, tail: tail).durationMs, 60_000)
    }

    func testOggVorbisCommentPacketSpanningTwoPages() {
        let ident: [UInt8] = F.cat([1], F.ascii("vorbis"), F.le32(0), [2], F.le32(44_100), F.zeros(14))
        // Comment packet of exactly 300 bytes: 255 on one page (lacing 255 = continues), 45 on the next.
        let body: [UInt8] = O.comments(vendor: String(repeating: "x", count: 262), ["ARTIST=Long Artist"])
        let packet: [UInt8] = F.cat([3], F.ascii("vorbis"), body, [1])
        XCTAssertEqual(packet.count, 300)
        let prefix: [UInt8] = F.cat(
            O.page(lacing: [F.byte(ident.count)], payload: ident, headerType: 2),
            O.page(lacing: [255], payload: Array(packet[0..<255])),
            O.page(lacing: [45], payload: Array(packet[255...]), headerType: 1))
        let tail: [UInt8] = O.page(lacing: [1], payload: [0], granule: 44_100 * 30, headerType: 4)
        let m = MetadataReader.read(prefix, tail: tail)
        XCTAssertEqual(m.codec, Codec.vorbis)
        XCTAssertEqual(m.artist, "Long Artist")
        XCTAssertEqual(m.durationMs, 30_000)
    }

    func testFuzzMP4AndOggNeverTrap() {
        let alac = M.sampleEntry("alac", channels: 2, rate: 0, children: M.alacConfig(bitDepth: 16, channels: 2, rate: 44_100))
        let mp4: [UInt8] = F.cat(M.ftyp, M.atom("moov", F.cat(M.track(timescale: 1_000, duration: 5_000, entry: alac), M.tags())))
        let opusHead: [UInt8] = F.cat(F.ascii("OpusHead"), [1, 2], F.zeros(9))
        let tags: [UInt8] = F.cat(F.ascii("OpusTags"), O.comments(vendor: "v", ["TITLE=t"]))
        let ogg: [UInt8] = F.cat(O.page(lacing: [19], payload: opusHead), O.page(lacing: [F.byte(tags.count)], payload: tags))
        let tail: [UInt8] = O.page(lacing: [1], payload: [0], granule: 96_000)

        var rng: UInt64 = 0xDEAD_BEEF_CAFE_F00D
        func next() -> Int {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: rng >> 33)
        }
        for seed in [mp4, ogg] {
            for length in 0...seed.count {
                let cut = Array(seed.prefix(length))
                _ = MetadataReader.read(cut, tail: cut)
            }
            for _ in 0..<2_000 {
                var mutated = seed
                var mutatedTail = tail
                for _ in 0..<(1 + next() % 8) { mutated[next() % mutated.count] = F.byte(next()) }
                mutatedTail[next() % mutatedTail.count] = F.byte(next())
                _ = MetadataReader.read(mutated, tail: mutatedTail)
                _ = MetadataReader.read(F.cat(M.ftyp, F.cat(F.be32(next()), F.ascii("mdat"))), tail: mutated)
            }
        }
    }
}
