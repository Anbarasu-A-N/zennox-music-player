import Foundation

enum ID3Parser {
    static func syncsafe(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Int {
        (Int(b0 & 0x7F) << 21) | (Int(b1 & 0x7F) << 14) | (Int(b2 & 0x7F) << 7) | Int(b3 & 0x7F)
    }

    /// Offset just past an ID3v2 tag at the start of `bytes` (0 if none).
    static func tagEnd(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 10, bytes.hasPrefix("ID3") else { return 0 }
        let footer = bytes[5] & 0x10 != 0 ? 10 : 0
        return 10 + syncsafe(bytes[6], bytes[7], bytes[8], bytes[9]) + footer
    }

    /// Parses ID3v2.3 / v2.4 text frames from a tag starting at `start`.
    static func parseTag(_ bytes: [UInt8], start: Int = 0, into m: inout AudioMetadata) {
        guard bytes.hasPrefix("ID3", at: start), bytes.count >= start + 10 else { return }
        let major = bytes[start + 3]
        let flags = bytes[start + 5]
        let size = syncsafe(bytes[start + 6], bytes[start + 7], bytes[start + 8], bytes[start + 9])
        let end = min(start + 10 + size, bytes.count)
        guard major == 3 || major == 4, flags & 0x80 == 0 else { return }  // v2.2 / unsynchronised: skip tags
        var r = ByteReader(bytes, offset: start + 10)
        do {
            if flags & 0x40 != 0 {  // extended header
                if major == 4 {
                    let b = try r.take(4)
                    try r.skip(syncsafe(b[0], b[1], b[2], b[3]) - 4)
                } else {
                    try r.skip(Int(try r.u32be()))
                }
            }
            while r.offset + 10 <= end {
                let idBytes = try r.take(4)
                if idBytes[0] == 0 { break }  // padding
                let raw = try r.u32be()
                let frameSize = major == 4
                    ? syncsafe(UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF))
                    : Int(raw)
                try r.skip(2)  // frame flags
                let id = String(decoding: idBytes, as: UTF8.self)
                if id == "APIC" { m.hasArtwork = true }
                guard frameSize > 0, r.offset + frameSize <= end else { break }
                let frame = try r.take(frameSize)
                switch id {
                case "TIT2": m.setText(\.title, text(frame))
                case "TPE1": m.setText(\.artist, text(frame))
                case "TALB": m.setText(\.album, text(frame))
                case "TPE2": m.setText(\.albumArtist, text(frame))
                case "TRCK": m.setNumber(\.trackNumber, text(frame))
                case "TPOS": m.setNumber(\.discNumber, text(frame))
                default: break
                }
            }
        } catch {}
    }

    static func text(_ frame: [UInt8]) -> String? {
        guard let encoding = frame.first else { return nil }
        let body = Array(frame.dropFirst())
        switch encoding {
        case 0: return String(bytes: body, encoding: .isoLatin1)
        case 1: return String(bytes: body, encoding: .utf16)
        case 2: return String(bytes: body, encoding: .utf16BigEndian)
        case 3: return String(bytes: body, encoding: .utf8)
        default: return nil
        }
    }
}

enum MP3Parser {
    private static let sampleRates: [[Int]] = [[11025, 12000, 8000], [], [22050, 24000, 16000], [44100, 48000, 32000]]
    private static let bitratesV1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let bitratesV2L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    static func parse(_ bytes: [UInt8], fileSize: Int64?) -> AudioMetadata {
        var m = AudioMetadata()
        m.container = .mp3
        m.codec = .mp3
        ID3Parser.parseTag(bytes, into: &m)
        let audioStart = ID3Parser.tagEnd(bytes)
        guard audioStart < bytes.count - 4 else { return m }
        let limit = min(bytes.count - 4, audioStart + 65_536)
        var i = audioStart
        while i < limit {
            if bytes[i] == 0xFF, bytes[i + 1] & 0xE0 == 0xE0, applyFrame(bytes, at: i, audioStart: audioStart, fileSize: fileSize, to: &m) {
                break
            }
            i += 1
        }
        return m
    }

    /// Validates an MPEG Layer III frame header at `i`; on success fills quality and duration.
    private static func applyFrame(_ b: [UInt8], at i: Int, audioStart: Int, fileSize: Int64?, to m: inout AudioMetadata) -> Bool {
        let version = Int((b[i + 1] >> 3) & 0x03)   // 0 = 2.5, 2 = 2, 3 = 1
        let layer = Int((b[i + 1] >> 1) & 0x03)     // 1 = Layer III
        let bitrateIndex = Int(b[i + 2] >> 4)
        let rateIndex = Int((b[i + 2] >> 2) & 0x03)
        guard version != 1, layer == 1, bitrateIndex != 0, bitrateIndex != 15, rateIndex != 3 else { return false }
        let sampleRate = sampleRates[version][rateIndex]
        let isMPEG1 = version == 3
        let kbps = (isMPEG1 ? bitratesV1L3 : bitratesV2L3)[bitrateIndex]
        let mono = (b[i + 3] >> 6) == 3
        m.sampleRate = sampleRate
        m.channels = mono ? 1 : 2

        let sideInfo = isMPEG1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        let samplesPerFrame: Int64 = isMPEG1 ? 1152 : 576
        let xing = i + 4 + sideInfo
        if b.hasPrefix("Xing", at: xing) || b.hasPrefix("Info", at: xing) {
            var r = ByteReader(b, offset: xing + 4)
            if let flags = try? r.u32be(), flags & 0x01 != 0, let frames = try? r.u32be(), frames > 0 {
                m.durationMs = Int64(frames) * samplesPerFrame * 1000 / Int64(sampleRate)
                return true
            }
        }
        if let fileSize, fileSize > Int64(audioStart) {
            m.durationMs = (fileSize - Int64(audioStart)) * 8 / Int64(kbps)
            m.durationIsEstimate = true
        }
        return true
    }
}
