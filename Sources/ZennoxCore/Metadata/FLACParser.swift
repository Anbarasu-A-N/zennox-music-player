import Foundation

enum FLACParser {
    static func parse(_ bytes: [UInt8], start: Int) -> AudioMetadata {
        var m = AudioMetadata()
        m.container = .flac
        m.codec = .flac
        var r = ByteReader(bytes, offset: start + 4)
        do {
            var isLast = false
            var blocks = 0
            while !isLast && blocks < 128 {
                blocks += 1
                let header = try r.u8()
                isLast = header & 0x80 != 0
                let type = header & 0x7F
                let length = Int(try r.u24be())
                if type == 6 { m.hasArtwork = true }
                let body = try r.take(length)  // a truncated (e.g. large picture) block ends parsing
                switch type {
                case 0: parseStreamInfo(body, into: &m)
                case 4: VorbisComments.apply(body, to: &m)
                default: break
                }
            }
        } catch {}
        return m
    }

    static func parseStreamInfo(_ s: [UInt8], into m: inout AudioMetadata) {
        guard s.count >= 18 else { return }
        let sampleRate = (Int(s[10]) << 12) | (Int(s[11]) << 4) | (Int(s[12]) >> 4)
        let channels = ((Int(s[12]) >> 1) & 0x07) + 1
        let bitDepth = (((Int(s[12]) & 0x01) << 4) | (Int(s[13]) >> 4)) + 1
        let totalSamples = (Int64(s[13] & 0x0F) << 32) | (Int64(s[14]) << 24) | (Int64(s[15]) << 16)
            | (Int64(s[16]) << 8) | Int64(s[17])
        guard sampleRate > 0 else { return }
        m.sampleRate = sampleRate
        m.channels = channels
        m.bitDepth = bitDepth
        if totalSamples > 0 { m.durationMs = totalSamples * 1000 / Int64(sampleRate) }
    }
}

enum VorbisComments {
    /// Vorbis comment block (FLAC block 4, Ogg comment packet after its signature).
    static func apply(_ body: [UInt8], to m: inout AudioMetadata) {
        var r = ByteReader(body)
        do {
            try r.skip(Int(try r.u32le()))  // vendor string
            let count = Int(try r.u32le())
            for _ in 0..<min(count, 10_000) {
                let entry = try r.take(Int(try r.u32le()))
                guard let text = String(bytes: entry, encoding: .utf8),
                      let eq = text.firstIndex(of: "=") else { continue }
                m.applyTag(key: String(text[..<eq]), value: String(text[text.index(after: eq)...]))
            }
        } catch {}
    }
}
