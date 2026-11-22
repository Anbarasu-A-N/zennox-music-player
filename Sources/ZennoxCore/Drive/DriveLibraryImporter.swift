import Foundation

public struct DriveImportReport: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var skipped = 0       // not audio (folder, document, unrecognised bytes)
    public var unavailable = 0   // deleted, trashed or access revoked
    public var invalidIDs = 0
}

public struct DriveRefreshReport: Equatable, Sendable {
    public var unchanged = 0
    public var updated = 0
    public var missing = 0       // in Drive trash
    public var inaccessible = 0  // deleted or access revoked (Drive does not say which)
}

// In extensions so the memberwise initializers stay available.
extension DriveImportReport { public init() {} }
extension DriveRefreshReport { public init() {} }

/// Turns Picker selections into library tracks (external_id = Drive file ID) and re-checks them
/// later. Reads only a bounded prefix (and tail when needed) of each file; never downloads whole
/// files and never writes to Drive.
public final class DriveLibraryImporter {
    private let store: LibraryStore
    private let drive: GoogleDriveClient

    public init(store: LibraryStore, drive: GoogleDriveClient) {
        self.store = store
        self.drive = drive
    }

    /// One library source per Google account, keyed by the stable Drive permission ID.
    public func ensureSource(for user: DriveUser) throws -> SourceID {
        try store.addSource(kind: .googleDrive, accountID: user.permissionID,
                            displayName: user.email ?? user.displayName ?? "Google Drive")
    }

    public func importPicked(_ ids: [String], into source: SourceID) async throws -> DriveImportReport {
        var report = DriveImportReport()
        for id in Array(Set(ids)).sorted() {
            guard GoogleDriveClient.isValidFileID(id) else { report.invalidIDs += 1; continue }
            let file: DriveFile
            do {
                file = try await drive.file(id)
            } catch DriveError.notFound, DriveError.forbidden {
                report.unavailable += 1
                continue
            }
            if file.trashed { report.unavailable += 1; continue }
            guard Self.looksLikeAudio(file), let input = try await readTrack(file) else { report.skipped += 1; continue }
            let existed = try store.trackID(source: source, externalID: file.id) != nil
            let track = try store.upsertTrack(input, in: source)
            try store.setRemoteInfo(track, contentHash: file.md5.map { "md5:" + $0 }, modified: Self.milliseconds(file.modifiedTime))
            if existed { report.updated += 1 } else { report.added += 1 }
        }
        return report
    }

    /// Re-checks every Drive track of this source. Unchanged files cost one metadata call each.
    public func refresh(_ source: SourceID) async throws -> DriveRefreshReport {
        var report = DriveRefreshReport()
        for known in try store.remoteTracks(in: source) {
            let file: DriveFile
            do {
                file = try await drive.file(known.externalID)
            } catch DriveError.notFound, DriveError.forbidden, DriveError.invalidFileID {
                try store.setStatus(.inaccessible, for: known.trackID)
                report.inaccessible += 1
                continue
            }
            if file.trashed {
                try store.setStatus(.missing, for: known.trackID)
                report.missing += 1
                continue
            }
            let hash = file.md5.map { "md5:" + $0 }
            let modified = Self.milliseconds(file.modifiedTime)
            if hash == known.contentHash, modified == known.modified {
                if known.status != .ok { try store.setStatus(.ok, for: known.trackID) }
                report.unchanged += 1
            } else if let input = try await readTrack(file) {
                let track = try store.upsertTrack(input, in: source)
                try store.setRemoteInfo(track, contentHash: hash, modified: modified)
                report.updated += 1
            } else {
                try store.setStatus(.inaccessible, for: known.trackID)
                report.inaccessible += 1
            }
        }
        return report
    }

    static func looksLikeAudio(_ file: DriveFile) -> Bool {
        if file.mimeType == "application/vnd.google-apps.folder" || file.mimeType.hasPrefix("application/vnd.google-apps.") {
            return false
        }
        if file.mimeType.hasPrefix("audio/") { return true }
        // Drive often labels FLAC/Opus as application/octet-stream; fall back to the extension, then the bytes decide.
        let ext = (file.name as NSString).pathExtension.lowercased()
        return LocalLibraryScanner.audioExtensions.contains(ext)
    }

    private func readTrack(_ file: DriveFile) async throws -> TrackInput? {
        let prefix = try await drive.read(file.id, offset: 0, length: MetadataReader.recommendedPrefixBytes)
        var metadata = MetadataReader.read(prefix, fileSize: file.size)
        if metadata.needsTailBytes, let size = file.size, size > Int64(prefix.count) {
            let n = MetadataReader.recommendedTailBytes
            let tail = try await drive.read(file.id, offset: max(0, size - Int64(n)), length: n)
            metadata = MetadataReader.read(prefix, fileSize: size, tail: tail)
        }
        guard metadata.container != .unknown else { return nil }
        return TrackInput(externalID: file.id, fileName: file.name, metadata: metadata,
                          fileSize: file.size, mimeType: file.mimeType)
    }

    static func milliseconds(_ iso: String?) -> Int64? {
        guard let iso else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = withFraction.date(from: iso) ?? plain.date(from: iso) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
