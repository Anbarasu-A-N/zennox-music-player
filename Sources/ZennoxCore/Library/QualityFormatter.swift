import Foundation

/// Text for quality badges and durations. Describes the source file only; what the output device
/// plays may differ (shown separately once playback exists).
public enum QualityFormatter {
    public static func codecName(_ codec: Codec) -> String {
        switch codec {
        case .flac: return "FLAC"
        case .alac: return "ALAC"
        case .pcm: return "PCM"
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .vorbis: return "Vorbis"
        case .opus: return "Opus"
        case .unknown: return "Unknown"
        }
    }

    /// Short badge: "Lossless" only when the decoded codec is lossless, never from the extension.
    public static func badge(_ codec: Codec) -> String {
        codec.isLossless ? "Lossless" : codecName(codec)
    }

    /// e.g. "FLAC · 24-bit · 96 kHz · Stereo". Bit depth is only shown for lossless sources.
    public static func summary(codec: Codec, bitDepth: Int?, sampleRate: Int?, channels: Int?) -> String {
        var parts = [codecName(codec)]
        if codec.isLossless, let bitDepth, bitDepth > 0 { parts.append("\(bitDepth)-bit") }
        if let sampleRate, sampleRate > 0 { parts.append(kilohertz(sampleRate)) }
        if let channels, channels > 0 { parts.append(channelName(channels)) }
        return parts.joined(separator: " · ")
    }

    static func kilohertz(_ hz: Int) -> String {
        if hz % 1000 == 0 { return "\(hz / 1000) kHz" }
        let tenths = Int((Double(hz) / 100).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10) kHz" : "\(tenths / 10).\(tenths % 10) kHz"
    }

    static func channelName(_ n: Int) -> String {
        switch n {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(n) ch"
        }
    }

    /// "3:05", "1:02:03"; "–:––" when unknown.
    public static func duration(ms: Int64?) -> String {
        guard let ms, ms >= 0 else { return "–:––" }
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let ss = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 { return "\(h):\(m < 10 ? "0\(m)" : "\(m)"):\(ss)" }
        return "\(m):\(ss)"
    }
}
