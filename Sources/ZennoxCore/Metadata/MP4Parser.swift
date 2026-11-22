import Foundation

/// MP4 / M4A (ISO BMFF). Codec comes from the audio track's sample description, so ALAC is told
/// apart from AAC by the stream itself, not the ".m4a" extension.
enum MP4Parser {
    private struct Atom {
        let type: String
        let start: Int  // body start
        let end: Int    // body end, clamped to available bytes
    }

    private struct TrackInfo {
        var isSound = false
        var codec: Codec?
        var sampleRate: Int?
        var channels: Int?
        var bitDepth: Int?
        var timescale: UInt64 = 0
        var duration: UInt64 = 0
    }

    static func parse(_ prefix: [UInt8], tail: [UInt8]?) -> AudioMetadata {
        var m = AudioMetadata()
        m.container = .mp4
        if let moov = topLevelMoov(prefix) {
            parseMoov(prefix, moov, into: &m)
        } else if let tail, let moov = moovInTail(tail) {
            parseMoov(tail, moov, into: &m)
        } else {
            m.needsTailBytes = true  // "moov after mdat": caller should fetch the file's last bytes
        }
        return m
    }

    // MARK: Atom walking

    private static func latin1(_ b: [UInt8], _ i: Int) -> String {
        String(bytes: b[i..<(i + 4)], encoding: .isoLatin1) ?? ""
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i]) << 8) | Int(b[i + 1]) }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt64 {
        (UInt64(b[i]) << 24) | (UInt64(b[i + 1]) << 16) | (UInt64(b[i + 2]) << 8) | UInt64(b[i + 3])
    }

    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 { (be32(b, i) << 32) | be32(b, i + 4) }

    private static func children(_ b: [UInt8], _ start: Int, _ end: Int) -> [Atom] {
        let limit = min(end, b.count)
        var atoms: [Atom] = []
        var i = start
        while i >= 0, i + 8 <= limit, atoms.count < 512 {
            var size = Int(be32(b, i))
            var header = 8
            if size == 1 {
                guard i + 16 <= limit else { break }
                size = Int(min(be64(b, i + 8), UInt64(Int.max / 4)))
                header = 16
            } else if size == 0 {
                size = limit - i
            }
            guard size >= header else { break }
            let atomEnd = i + size
            atoms.append(Atom(type: latin1(b, i + 4), start: i + header, end: min(atomEnd, limit)))
            if atomEnd > limit { break }
            i = atomEnd
        }
        return atoms
    }

    private static func topLevelMoov(_ b: [UInt8]) -> Atom? {
        children(b, 0, b.count).first { $0.type == "moov" }
    }

    /// Finds a moov atom inside the file's last bytes; requires a known first child to avoid false hits in audio data.
    private static func moovInTail(_ b: [UInt8]) -> Atom? {
        guard b.count >= 16 else { return nil }
        for i in 0...(b.count - 16) where b.hasPrefix("moov", at: i + 4) {
            let size = Int(be32(b, i))
            let firstChild = latin1(b, i + 12)
            guard size >= 16, ["mvhd", "trak", "udta", "meta"].contains(firstChild) else { continue }
            return Atom(type: "moov", start: i + 8, end: min(i + size, b.count))
        }
        return nil
    }

    // MARK: moov

    private static func parseMoov(_ b: [UInt8], _ moov: Atom, into m: inout AudioMetadata) {
        var movieTimescale: UInt64 = 0
        var movieDuration: UInt64 = 0
        var audio: TrackInfo?
        for atom in children(b, moov.start, moov.end) {
            switch atom.type {
            case "mvhd":
                if let t = timing(b, atom) { movieTimescale = t.timescale; movieDuration = t.duration }
            case "trak":
                let track = parseTrak(b, atom)
                if audio == nil, track.isSound || track.codec != nil { audio = track }
            case "udta":
                for child in children(b, atom.start, atom.end) where child.type == "meta" { parseMeta(b, child, into: &m) }
            case "meta":
                parseMeta(b, atom, into: &m)
            default:
                break
            }
        }
        if let audio {
            m.codec = audio.codec ?? .unknown
            m.sampleRate = audio.sampleRate
            m.channels = audio.channels
            m.bitDepth = m.codec.isLossless ? audio.bitDepth : nil
            if let ms = milliseconds(audio.duration, audio.timescale) { m.durationMs = ms }
        }
        if m.durationMs == nil, let ms = milliseconds(movieDuration, movieTimescale) { m.durationMs = ms }
    }

    private static func milliseconds(_ duration: UInt64, _ timescale: UInt64) -> Int64? {
        guard timescale > 0, duration > 0, duration != UInt64(UInt32.max), duration != UInt64.max,
              duration < UInt64(Int64.max / 1000) else { return nil }
        return Int64(duration * 1000 / timescale)
    }

    /// mvhd / mdhd: (timescale, duration) for version 0 and 1 boxes.
    private static func timing(_ b: [UInt8], _ atom: Atom) -> (timescale: UInt64, duration: UInt64)? {
        guard atom.start < atom.end else { return nil }
        if b[atom.start] == 1 {
            guard atom.start + 32 <= atom.end else { return nil }
            return (be32(b, atom.start + 20), be64(b, atom.start + 24))
        }
        guard atom.start + 20 <= atom.end else { return nil }
        return (be32(b, atom.start + 12), be32(b, atom.start + 16))
    }

    private static func parseTrak(_ b: [UInt8], _ trak: Atom) -> TrackInfo {
        var t = TrackInfo()
        for mdia in children(b, trak.start, trak.end) where mdia.type == "mdia" {
            for atom in children(b, mdia.start, mdia.end) {
                switch atom.type {
                case "mdhd":
                    if let tm = timing(b, atom) { t.timescale = tm.timescale; t.duration = tm.duration }
                case "hdlr":
                    if atom.start + 12 <= atom.end { t.isSound = latin1(b, atom.start + 8) == "soun" }
                case "minf":
                    for stbl in children(b, atom.start, atom.end) where stbl.type == "stbl" {
                        for stsd in children(b, stbl.start, stbl.end) where stsd.type == "stsd" {
                            parseSampleDescription(b, stsd, into: &t)
                        }
                    }
                default:
                    break
                }
            }
        }
        return t
    }

    private static func parseSampleDescription(_ b: [UInt8], _ stsd: Atom, into t: inout TrackInfo) {
        let entry = stsd.start + 8  // version/flags + entry count
        guard entry + 36 <= stsd.end else { return }
        let entryEnd = min(entry + Int(be32(b, entry)), stsd.end)
        let format = latin1(b, entry + 4)
        switch format {
        case "alac": t.codec = .alac
        case "fLaC": t.codec = .flac
        case "mp4a": t.codec = .aac
        case "Opus": t.codec = .opus
        case ".mp3": t.codec = .mp3
        default: return
        }
        let version = be16(b, entry + 16)
        t.channels = be16(b, entry + 24)
        let rate = Int(be32(b, entry + 32) >> 16)  // 16.16 fixed point; 0 or wrapped above 65535 Hz
        if rate > 0 { t.sampleRate = rate }
        let childStart = entry + 36 + (version == 1 ? 16 : version == 2 ? 36 : 0)
        for child in children(b, childStart, entryEnd) {
            if child.type == "alac", child.start + 28 <= child.end {
                // ALACSpecificConfig after the 4-byte full-box header
                t.bitDepth = Int(b[child.start + 9])
                t.channels = Int(b[child.start + 13])
                let alacRate = Int(be32(b, child.start + 24))
                if alacRate > 0 { t.sampleRate = alacRate }
            } else if child.type == "dfLa", child.start + 8 + 18 <= child.end {
                var info = AudioMetadata()
                FLACParser.parseStreamInfo(Array(b[(child.start + 8)..<child.end]), into: &info)
                t.bitDepth = info.bitDepth ?? t.bitDepth
                t.sampleRate = info.sampleRate ?? t.sampleRate
                t.channels = info.channels ?? t.channels
            }
        }
    }

    // MARK: iTunes-style tags

    private static func parseMeta(_ b: [UInt8], _ meta: Atom, into m: inout AudioMetadata) {
        // ISO meta is a full box (4 bytes version/flags); QuickTime meta is not.
        let isFullBox = meta.start + 8 <= meta.end && latin1(b, meta.start + 4) != "hdlr"
        let start = isFullBox ? meta.start + 4 : meta.start
        for ilst in children(b, start, meta.end) where ilst.type == "ilst" {
            for item in children(b, ilst.start, ilst.end) {
                if item.type == "covr" { m.hasArtwork = true; continue }
                guard let data = children(b, item.start, item.end).first(where: { $0.type == "data" }),
                      data.start + 8 <= data.end else { continue }
                let value = Array(b[(data.start + 8)..<data.end])  // skip type + locale
                switch item.type {
                case "\u{A9}nam": m.setText(\.title, String(bytes: value, encoding: .utf8))
                case "\u{A9}ART": m.setText(\.artist, String(bytes: value, encoding: .utf8))
                case "\u{A9}alb": m.setText(\.album, String(bytes: value, encoding: .utf8))
                case "aART": m.setText(\.albumArtist, String(bytes: value, encoding: .utf8))
                case "trkn": if value.count >= 4, m.trackNumber == nil { m.trackNumber = positive(be16(value, 2)) }
                case "disk": if value.count >= 4, m.discNumber == nil { m.discNumber = positive(be16(value, 2)) }
                default: break
                }
            }
        }
    }

    private static func positive(_ v: Int) -> Int? { v > 0 ? v : nil }
}
