import Foundation

public struct SourceID: Hashable, Sendable { public let rawValue: Int64 }
public struct TrackID: Hashable, Sendable { public let rawValue: Int64 }
public struct PlaylistID: Hashable, Sendable { public let rawValue: Int64 }
public struct RootID: Hashable, Sendable { public let rawValue: Int64 }

public enum RootKind: String, Sendable { case folder, file }
public enum RootStatus: String, Sendable { case ok, inaccessible }

/// A folder or single file the user added. `accessToken` is a platform grant
/// (base64 security-scoped bookmark on Apple, persisted SAF URI on Android).
public struct LibraryRoot: Equatable, Sendable {
    public let id: RootID
    public let kind: RootKind
    public let displayPath: String
    public let accessToken: String?
    public let status: RootStatus

    public init(id: RootID, kind: RootKind, displayPath: String, accessToken: String?, status: RootStatus) {
        self.id = id; self.kind = kind; self.displayPath = displayPath; self.accessToken = accessToken; self.status = status
    }
}

/// What the library last recorded about a local file, for matching during a rescan.
public struct KnownFile: Equatable, Sendable {
    public let trackID: TrackID
    public let externalID: String
    public let path: String?
    public let identity: String?
    public let size: Int64?
    public let modified: Int64?
    public let status: TrackStatus
}

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

extension TrackInput {
    /// Builds a library entry from parsed metadata. Title falls back to the file name without extension.
    public init(externalID: String, path: String? = nil, fileName: String, metadata m: AudioMetadata,
                fileSize: Int64? = nil, mimeType: String? = nil) {
        let base = (fileName as NSString).deletingPathExtension
        self.init(externalID: externalID, path: path, title: m.title ?? (base.isEmpty ? fileName : base),
                  artist: m.artist, album: m.album, albumArtist: m.albumArtist,
                  trackNumber: m.trackNumber, discNumber: m.discNumber, durationMs: m.durationMs,
                  codec: m.codec, sampleRate: m.sampleRate, bitDepth: m.bitDepth, channels: m.channels,
                  fileSize: fileSize, mimeType: mimeType)
    }
}

/// What the library last recorded about a cloud file, for change detection on refresh.
public struct RemoteTrack: Equatable, Sendable {
    public let trackID: TrackID
    public let externalID: String
    public let contentHash: String?
    public let modified: Int64?
    public let status: TrackStatus
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
