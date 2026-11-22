import Foundation

/// Ogg Opus / Vorbis / FLAC. Headers and comments come from the first pages; duration needs the
/// last page's granule position, so pass the file's last bytes as `tail` (or check needsTailBytes).
enum OggParser {
    static func parse(_ bytes: [UInt8], tail: [UInt8]?) -> AudioMetadata {
        var m = AudioMetadata()
        m.container = .ogg
        let packets = firstPackets(bytes, count: 2)
        guard let ident = packets.first else { return m }

        var preSkip: UInt64 = 0
        var granuleRate = 0
        if ident.hasPrefix("OpusHead"), ident.count >= 19 {
            m.codec = .opus
            m.channels = Int(ident[9])
            preSkip = UInt64(ident[10]) | (UInt64(ident[11]) << 8)
            m.sampleRate = 48_000  // Opus always decodes at 48 kHz
            granuleRate = 48_000
        } else if ident.count >= 16, ident[0] == 0x01, ident.hasPrefix("vorbis", at: 1) {
            m.codec = .vorbis
            m.channels = Int(ident[11])
            let rate = Int(ident[12]) | (Int(ident[13]) << 8) | (Int(ident[14]) << 16) | (Int(ident[15]) << 24)
            if rate > 0 { m.sampleRate = rate; granuleRate = rate }
        } else if ident.count >= 17 + 18, ident[0] == 0x7F, ident.hasPrefix("FLAC", at: 1) {
            m.codec = .flac
            FLACParser.parseStreamInfo(Array(ident[17...]), into: &m)
            m.durationMs = nil  // stream info total may be 0; use granule below
            granuleRate = m.sampleRate ?? 0
        }

        if packets.count > 1 {
            let c = packets[1]
            switch m.codec {
            case .opus where c.hasPrefix("OpusTags"): VorbisComments.apply(Array(c.dropFirst(8)), to: &m)
            case .vorbis where c.first == 0x03 && c.hasPrefix("vorbis", at: 1): VorbisComments.apply(Array(c.dropFirst(7)), to: &m)
            case .flac where (c.first ?? 0) & 0x7F == 4: VorbisComments.apply(Array(c.dropFirst(4)), to: &m)
            default: break
            }
        }

        if let tail, granuleRate > 0, let granule = lastGranule(tail), granule > preSkip,
           granule - preSkip < UInt64(Int64.max) / 1000 {
            m.durationMs = Int64((granule - preSkip) * 1000 / UInt64(granuleRate))
        } else if m.codec != .unknown {
            m.needsTailBytes = true
        }
        return m
    }

    /// Reassembles the first `count` packets across pages (lacing value 255 = packet continues).
    /// A packet cut off by the end of the buffer is returned partially (enough for most comments).
    static func firstPackets(_ b: [UInt8], count: Int) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        var i = 0
        var pages = 0
        pageLoop: while i + 27 <= b.count, packets.count < count, pages < 64 {
            guard b.hasPrefix("OggS", at: i) else { break }
            let segmentCount = Int(b[i + 26])
            let table = i + 27
            guard table + segmentCount <= b.count else { break }
            var p = table + segmentCount
            for k in 0..<segmentCount {
                let length = Int(b[table + k])
                guard p <= b.count else { break pageLoop }
                current.append(contentsOf: b[p..<min(p + length, b.count)])
                p += length
                if current.count > 2_000_000 { break pageLoop }
                if length < 255 {
                    packets.append(current)
                    current = []
                    if packets.count == count { break pageLoop }
                }
            }
            i = p
            pages += 1
        }
        if packets.count < count, !current.isEmpty { packets.append(current) }
        return packets
    }

    /// Granule position of the last complete page in the buffer.
    static func lastGranule(_ b: [UInt8]) -> UInt64? {
        guard b.count >= 27 else { return nil }
        var i = b.count - 27
        while i >= 0 {
            if b.hasPrefix("OggS", at: i), b[i + 4] == 0 {
                var g: UInt64 = 0
                for k in (0..<8).reversed() { g = (g << 8) | UInt64(b[i + 6 + k]) }
                if g != UInt64.max { return g }
            }
            i -= 1
        }
        return nil
    }
}
