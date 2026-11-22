import Foundation

/// Reads format, quality and tags from the first bytes of an audio file.
/// Callers pass a bounded prefix (e.g. the first 256 KB from disk or an HTTP Range request) and,
/// when known, the full file size. Never throws and never traps on malformed input: it returns
/// whatever it could read.
public enum MetadataReader {
    public static let recommendedPrefixBytes = 256 * 1024

    public static func read(_ bytes: [UInt8], fileSize: Int64? = nil) -> AudioMetadata {
        if bytes.hasPrefix("fLaC") { return FLACParser.parse(bytes, start: 0) }
        if bytes.hasPrefix("ID3") {
            let tagEnd = ID3Parser.tagEnd(bytes)
            if bytes.hasPrefix("fLaC", at: tagEnd) {  // FLAC with a (non-standard) leading ID3 tag
                return FLACParser.parse(bytes, start: tagEnd)
            }
            return MP3Parser.parse(bytes, fileSize: fileSize)
        }
        if bytes.hasPrefix("RIFF"), bytes.hasPrefix("WAVE", at: 8) { return WAVParser.parse(bytes) }
        if bytes.hasPrefix("FORM"), bytes.hasPrefix("AIFF", at: 8) || bytes.hasPrefix("AIFC", at: 8) {
            return AIFFParser.parse(bytes)
        }
        if bytes.hasPrefix("OggS") { return OggParser.parse(bytes) }
        if bytes.hasPrefix("ftyp", at: 4) {
            var m = AudioMetadata()
            m.container = .mp4  // codec/tags from MP4 atoms: slice L2b
            return m
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            return MP3Parser.parse(bytes, fileSize: fileSize)
        }
        return AudioMetadata()
    }
}
