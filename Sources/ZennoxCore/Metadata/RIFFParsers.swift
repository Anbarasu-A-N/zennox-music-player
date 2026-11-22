import Foundation

enum WAVParser {
    static func parse(_ bytes: [UInt8]) -> AudioMetadata {
        var m = AudioMetadata()
        m.container = .wav
        var r = ByteReader(bytes, offset: 12)
        var byteRate: UInt32 = 0
        do {
            for _ in 0..<64 {
                let id = try r.fourCC()
                let size = Int(try r.u32le())
                if id == "fmt " {
                    var f = ByteReader(try r.take(size))
                    var format = try f.u16le()
                    m.channels = Int(try f.u16le())
                    m.sampleRate = Int(try f.u32le())
                    byteRate = try f.u32le()
                    _ = try f.u16le()  // block align
                    m.bitDepth = Int(try f.u16le())
                    if format == 0xFFFE, size >= 40 {  // WAVE_FORMAT_EXTENSIBLE: real format in SubFormat GUID
                        try f.skip(8)
                        format = try f.u16le()
                    }
                    // PCM (1) and IEEE float (3) are lossless; anything else (ADPCM, MP3-in-WAV…) is not claimed.
                    m.codec = (format == 1 || format == 3) ? .pcm : .unknown
                    if size & 1 == 1 { try r.skip(1) }
                } else if id == "data" {
                    if byteRate > 0 { m.durationMs = Int64(size) * 1000 / Int64(byteRate) }
                    break
                } else {
                    try r.skip(size + (size & 1))
                }
            }
        } catch {}
        if m.codec != .pcm { m.bitDepth = nil }
        return m
    }
}

enum AIFFParser {
    private static let pcmCompression: Set<String> = ["NONE", "sowt", "twos", "in24", "in32", "fl32", "fl64", "FL32", "FL64"]

    static func parse(_ bytes: [UInt8]) -> AudioMetadata {
        var m = AudioMetadata()
        m.container = .aiff
        let isAIFC = bytes.hasPrefix("AIFC", at: 8)
        m.codec = isAIFC ? .unknown : .pcm
        var r = ByteReader(bytes, offset: 12)
        do {
            for _ in 0..<64 {
                let id = try r.fourCC()
                let size = Int(try r.u32be())
                if id == "SSND" { break }  // audio data; tags after it are beyond the prefix
                let body = try r.take(size)
                if size & 1 == 1 { try? r.skip(1) }
                if id == "COMM" {
                    var c = ByteReader(body)
                    let channels = Int(try c.u16be())
                    let frames = Int64(try c.u32be())
                    let bits = Int(try c.u16be())
                    let rate = extended80(try c.take(10))
                    m.channels = channels
                    m.bitDepth = bits
                    if rate >= 1 && rate < 10_000_000 {
                        m.sampleRate = Int(rate.rounded())
                        m.durationMs = frames * 1000 / Int64(rate.rounded())
                    }
                    if isAIFC, let type = try? c.fourCC(), pcmCompression.contains(type) { m.codec = .pcm }
                } else if id == "ID3 " || id == "id3 " {
                    ID3Parser.parseTag(body, into: &m)
                }
            }
        } catch {}
        if m.codec != .pcm { m.bitDepth = nil }
        return m
    }

    /// IEEE 754 80-bit extended float (big-endian), as used for AIFF sample rates.
    static func extended80(_ b: [UInt8]) -> Double {
        guard b.count == 10 else { return 0 }
        let exponent = (Int(b[0] & 0x7F) << 8) | Int(b[1])
        var mantissa: UInt64 = 0
        for byte in b[2..<10] { mantissa = (mantissa << 8) | UInt64(byte) }
        guard exponent != 0 || mantissa != 0, exponent != 0x7FFF else { return 0 }
        return Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
    }
}

enum OggParser {
    /// Identifies the codec from the first Ogg page. Duration and comments need later pages (L2b).
    static func parse(_ bytes: [UInt8]) -> AudioMetadata {
        var m = AudioMetadata()
        m.container = .ogg
        guard bytes.count >= 27 else { return m }
        let payload = 27 + Int(bytes[26])
        var r = ByteReader(bytes, offset: payload)
        if bytes.hasPrefix("OpusHead", at: payload) {
            m.codec = .opus
            do {
                try r.skip(9)
                m.channels = Int(try r.u8())
                m.sampleRate = 48_000  // Opus always decodes at 48 kHz
            } catch {}
        } else if bytes.count > payload, bytes[payload] == 0x01, bytes.hasPrefix("vorbis", at: payload + 1) {
            m.codec = .vorbis
            do {
                try r.skip(11)
                m.channels = Int(try r.u8())
                m.sampleRate = Int(try r.u32le())
            } catch {}
        } else if bytes.count > payload, bytes[payload] == 0x7F, bytes.hasPrefix("FLAC", at: payload + 1) {
            m.codec = .flac
        }
        return m
    }
}
