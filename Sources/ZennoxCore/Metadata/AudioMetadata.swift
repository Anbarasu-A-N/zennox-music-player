import Foundation

public enum Container: String, Sendable {
    case flac, mp3, wav, aiff, ogg, mp4, unknown
}

/// What a file says about itself. Quality fields come from stream headers, never file names.
public struct AudioMetadata: Equatable, Sendable {
    public var container: Container = .unknown
    public var codec: Codec = .unknown
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?
    public var durationMs: Int64?
    /// True when duration was estimated from file size and bitrate (CBR MP3 without a Xing header).
    public var durationIsEstimate = false
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var hasArtwork = false

    public var isLossless: Bool { codec.isLossless }

    public init() {}

    mutating func setText(_ field: WritableKeyPath<AudioMetadata, String?>, _ raw: String?) {
        guard self[keyPath: field] == nil, let value = Self.clean(raw) else { return }
        self[keyPath: field] = value
    }

    mutating func setNumber(_ field: WritableKeyPath<AudioMetadata, Int?>, _ raw: String?) {
        guard self[keyPath: field] == nil, let value = Self.clean(raw),
              let first = value.split(separator: "/").first,
              let number = Int(first.trimmingCharacters(in: .whitespaces)), number > 0 else { return }
        self[keyPath: field] = number
    }

    /// Applies a Vorbis-comment / generic tag key (case-insensitive).
    mutating func applyTag(key: String, value: String) {
        switch key.uppercased() {
        case "TITLE": setText(\.title, value)
        case "ARTIST": setText(\.artist, value)
        case "ALBUM": setText(\.album, value)
        case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": setText(\.albumArtist, value)
        case "TRACKNUMBER": setNumber(\.trackNumber, value)
        case "DISCNUMBER": setNumber(\.discNumber, value)
        case "METADATA_BLOCK_PICTURE": hasArtwork = true
        default: break
        }
    }

    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.split(separator: "\u{0}", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(1024))  // cap absurd tag lengths
    }
}
