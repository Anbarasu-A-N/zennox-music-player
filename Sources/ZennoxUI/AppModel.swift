#if canImport(SwiftUI)
import Foundation
import Observation
import ZennoxCore

public enum LibrarySection: String, Hashable, CaseIterable, Identifiable {
    case songs, albums, artists, folders, favorites, recentlyAdded, recentlyPlayed, sources
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .songs: return "Songs"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .folders: return "Folders"
        case .favorites: return "Favorites"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .sources: return "Sources"
        }
    }

    public var symbol: String {
        switch self {
        case .songs: return "music.note"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .folders: return "folder"
        case .favorites: return "heart"
        case .recentlyAdded: return "clock.badge.plus"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .sources: return "externaldrive"
        }
    }
}

/// UI state on the main actor. Reads use the main connection; scans run off the main thread on
/// their own connection (SQLite WAL), then the UI reloads.
@MainActor
@Observable
public final class AppModel {
    public var section: LibrarySection? = .songs
    public private(set) var sort: TrackSort = .title
    public private(set) var songs: [TrackRow] = []
    public private(set) var albums: [AlbumRow] = []
    public private(set) var artists: [ArtistRow] = []
    public private(set) var folders: [FolderRow] = []
    public private(set) var favorites: [TrackRow] = []
    public private(set) var recentlyAdded: [TrackRow] = []
    public private(set) var recentlyPlayed: [TrackRow] = []
    public private(set) var roots: [LibraryRoot] = []
    public private(set) var isScanning = false
    public private(set) var statusMessage: String?
    public var errorMessage: String?

    private let store: LibraryStore
    private let databasePath: String
    private let localSource: SourceID

    public init(databasePath: String? = nil) throws {
        let path = try databasePath ?? Self.defaultDatabasePath()
        self.databasePath = path
        store = try LibraryStore(database: SQLiteDatabase(path: path))
        localSource = try store.addSource(kind: .local, displayName: "This device")
        reload()
    }

    public static func defaultDatabasePath() throws -> String {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Zennox", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.sqlite").path
    }

    public func setSort(_ newValue: TrackSort) {
        sort = newValue
        reload()
    }

    public var isEmpty: Bool { songs.isEmpty && roots.isEmpty }

    public func reload() {
        do {
            songs = try store.allTracks(sort: sort)
            albums = try store.albums()
            artists = try store.artists()
            folders = try store.folders()
            favorites = try store.favoriteTracks()
            recentlyAdded = try store.recentlyAdded(limit: 100)
            recentlyPlayed = try store.recentlyPlayed(limit: 100)
            roots = try store.roots(in: localSource)
        } catch {
            errorMessage = "Couldn’t read the library: \(error.localizedDescription)"
        }
    }

    public func search(_ text: String) -> [TrackRow] {
        (try? store.search(text, limit: 200)) ?? []
    }

    public func tracks(inAlbum album: AlbumRow) -> [TrackRow] { (try? store.tracks(inAlbum: album.title, artist: album.artist)) ?? [] }
    public func tracks(byArtist artist: ArtistRow) -> [TrackRow] { (try? store.tracks(byArtist: artist.name)) ?? [] }
    public func tracks(inFolder folder: FolderRow) -> [TrackRow] { (try? store.tracks(inFolder: folder.path)) ?? [] }

    public func toggleFavorite(_ track: TrackRow) {
        do {
            try store.setFavorite(track.id, !track.isFavorite)
            reload()
        } catch {
            errorMessage = "Couldn’t update Favorites."
        }
    }

    // MARK: Local folders

    /// URLs come from the system file picker; only those folders become accessible to the app.
    public func addFolders(_ urls: [URL]) {
        var added: [LibraryRoot] = []
        for url in urls {
            do {
                let token = try SecurityScopedBookmark.make(for: url)
                let id = try store.addRoot(source: localSource, kind: .folder, displayPath: url.path, accessToken: token)
                added.append(LibraryRoot(id: id, kind: .folder, displayPath: url.path, accessToken: token, status: .ok))
            } catch {
                errorMessage = "Couldn’t add “\(url.lastPathComponent)”: \(error.localizedDescription)"
            }
        }
        reload()
        scan(added)
    }

    public func rescanAll() { scan(roots) }

    /// Removes the folder from the library. Files on disk are never touched.
    public func remove(_ root: LibraryRoot) {
        do {
            try store.removeRoot(root.id)
            reload()
        } catch {
            errorMessage = "Couldn’t remove the folder."
        }
    }

    private func scan(_ targets: [LibraryRoot]) {
        guard !targets.isEmpty, !isScanning else { return }
        isScanning = true
        statusMessage = "Scanning…"
        let path = databasePath
        let source = localSource
        Task.detached(priority: .utility) {
            let summary = Self.scanInBackground(targets, databasePath: path, source: source)
            await MainActor.run {
                self.isScanning = false
                self.statusMessage = summary
                self.reload()
            }
        }
    }

    nonisolated private static func scanInBackground(_ targets: [LibraryRoot], databasePath: String, source: SourceID) -> String {
        do {
            let store = try LibraryStore(database: SQLiteDatabase(path: databasePath))
            let scanner = LocalLibraryScanner(store: store)
            var total = ScanReport()
            for root in targets {
                guard let token = root.accessToken else {
                    try store.setRootStatus(.inaccessible, for: root.id)
                    continue
                }
                do {
                    let (report, refreshed) = try SecurityScopedBookmark.withAccess(token) { url in
                        try scanner.scan(root: root.id, path: url.path, source: source)
                    }
                    if let refreshed {
                        _ = try store.addRoot(source: source, kind: root.kind, displayPath: root.displayPath, accessToken: refreshed)
                    }
                    total.added += report.added
                    total.updated += report.updated
                    total.moved += report.moved
                    total.missing += report.missing
                } catch {
                    try store.setRootStatus(.inaccessible, for: root.id)
                }
            }
            try DuplicateDetector.detect(in: store)
            var parts: [String] = []
            if total.added > 0 { parts.append("\(total.added) added") }
            if total.updated > 0 { parts.append("\(total.updated) updated") }
            if total.moved > 0 { parts.append("\(total.moved) moved") }
            if total.missing > 0 { parts.append("\(total.missing) missing") }
            return parts.isEmpty ? "Library is up to date" : parts.joined(separator: " · ")
        } catch {
            return "Scan failed: \(error.localizedDescription)"
        }
    }
}
#endif
