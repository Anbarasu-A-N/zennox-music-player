import Foundation

public struct SourceID: Hashable, Sendable { public let rawValue: Int64 }
public struct TrackID: Hashable, Sendable { public let rawValue: Int64 }
public struct PlaylistID: Hashable, Sendable { public let rawValue: Int64 }

public enum SourceKind: String, Sendable {
    case local
    case googleDrive = "gdrive"
}

/// Codec of the decoded audio stream. Lossless is derived from this, never from a file extension.
public enum Codec: String, Sendable, CaseIterable {
    case flac, alac, pcm, mp3, aac, vorbis, opus, unknown

    public var isLossless: Bool {
        switch self {
        case .flac, .alac, .pcm: return true
        case .mp3, .aac, .vorbis, .opus, .unknown: return false
        }
    }
}

public enum TrackStatus: String, Sendable {
    case ok, missing, inaccessible
}

public struct TrackInput: Sendable {
    public var externalID: String
    public var path: String?
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var durationMs: Int64?
    public var codec: Codec
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?
    public var fileSize: Int64?
    public var mimeType: String?

    public init(externalID: String, path: String? = nil, title: String, artist: String? = nil,
                album: String? = nil, albumArtist: String? = nil, trackNumber: Int? = nil,
                discNumber: Int? = nil, durationMs: Int64? = nil, codec: Codec,
                sampleRate: Int? = nil, bitDepth: Int? = nil, channels: Int? = nil,
                fileSize: Int64? = nil, mimeType: String? = nil) {
        self.externalID = externalID; self.path = path; self.title = title; self.artist = artist
        self.album = album; self.albumArtist = albumArtist; self.trackNumber = trackNumber
        self.discNumber = discNumber; self.durationMs = durationMs; self.codec = codec
        self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.channels = channels
        self.fileSize = fileSize; self.mimeType = mimeType
    }
}

public struct TrackSummary: Equatable, Sendable {
    public let id: TrackID
    public let title: String
    public let codec: Codec
    public let isLossless: Bool
    public let status: TrackStatus
}

public enum LibraryError: Error, Equatable {
    case emptyPlaylistName
    case notFound
}
