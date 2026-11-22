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
        case .recentlyAdded: return "calendar.badge.plus"
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
        if !added.isEmpty { scan(roots) }
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
            let roots = try reconcile(try store.roots(in: source), store: store, source: source)
            var added = 0, updated = 0, moved = 0, missing = 0
            for (root, path) in roots {
                guard let token = root.accessToken, path != nil else {
                    try store.setRootStatus(.inaccessible, for: root.id)
                    continue
                }
                do {
                    let (report, _) = try SecurityScopedBookmark.withAccess(token) { url in
                        try scanner.scan(root: root.id, path: url.path, source: source)
                    }
                    added += report.added
                    updated += report.updated
                    moved += report.moved
                    missing += report.missing
                } catch {
                    try store.setRootStatus(.inaccessible, for: root.id)
                }
            }
            try DuplicateDetector.detect(in: store)
            var parts: [String] = []
            if added > 0 { parts.append("\(added) added") }
            if updated > 0 { parts.append("\(updated) updated") }
            if moved > 0 { parts.append("\(moved) moved") }
            if missing > 0 { parts.append("\(missing) missing") }
            return parts.isEmpty ? "Library is up to date" : parts.joined(separator: " · ")
        } catch {
            return "Scan failed: \(error.localizedDescription)"
        }
    }

    /// Resolves every folder's bookmark to where the folder is now. Bookmarks follow renames and
    /// moves, so two entries can turn out to be the same folder: those are merged into the oldest
    /// entry, and each remaining entry's shown path is brought up to date.
    nonisolated static func reconcile(_ roots: [LibraryRoot], store: LibraryStore, source: SourceID) throws -> [(LibraryRoot, String?)] {
        var resolved: [(root: LibraryRoot, path: String?, token: String?)] = []
        for root in roots.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            guard let token = root.accessToken,
                  let access = try? SecurityScopedBookmark.withAccess(token, { LocalFileSystem.canonical($0.path) }) else {
                resolved.append((root: root, path: nil, token: nil))
                continue
            }
            resolved.append((root: root, path: access.result, token: access.refreshedToken ?? token))
        }
        var keeperByPath: [String: RootID] = [:]
        var result: [(LibraryRoot, String?)] = []
        for entry in resolved {
            guard let path = entry.path else { result.append((entry.root, nil as String?)); continue }
            if let keeper = keeperByPath[path] {
                try store.mergeRoot(entry.root.id, into: keeper)
                continue
            }
            keeperByPath[path] = entry.root.id
            if path != entry.root.displayPath || entry.token != entry.root.accessToken {
                try? store.updateRoot(entry.root.id, displayPath: path, accessToken: entry.token)
            }
            result.append((LibraryRoot(id: entry.root.id, kind: entry.root.kind, displayPath: path,
                                       accessToken: entry.token, status: .ok), path))
        }
        return result
    }
}
#endif
