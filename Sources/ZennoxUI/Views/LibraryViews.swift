#if canImport(SwiftUI)
import SwiftUI
import ZennoxCore

struct TrackListView: View {
    let model: AppModel
    let title: String
    let tracks: [TrackRow]
    var emptyTitle = "Nothing here yet"
    var emptyMessage = "Add a folder of music to get started."
    var showsSort = false

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "music.note.list", description: Text(emptyMessage))
            } else {
                List(tracks, id: \.id) { track in
                    TrackRowView(track: track) { model.toggleFavorite(track) }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            if showsSort {
                ToolbarItem {
                    Menu {
                        Picker("Sort by", selection: Binding(get: { model.sort }, set: { model.setSort($0) })) {
                            Text("Title").tag(TrackSort.title)
                            Text("Artist").tag(TrackSort.artist)
                            Text("Album").tag(TrackSort.album)
                            Text("Recently Added").tag(TrackSort.recentlyAdded)
                            Text("Duration").tag(TrackSort.duration)
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
        }
    }
}

struct AlbumsView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.albums.isEmpty {
                ContentUnavailableView("No albums yet", systemImage: "square.stack", description: Text("Albums appear when songs have album tags."))
            } else {
                List(model.albums, id: \.self) { album in
                    NavigationLink {
                        TrackListView(model: model, title: album.title, tracks: model.tracks(inAlbum: album))
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkPlaceholder(size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title).lineLimit(1)
                                Text(album.artist.isEmpty ? "Unknown artist" : album.artist)
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if album.hasLossless { QualityBadge(codec: .flac) }
                            Text("\(album.trackCount)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Albums")
    }
}

struct ArtistsView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.artists.isEmpty {
                ContentUnavailableView("No artists yet", systemImage: "music.mic", description: Text("Artists appear when songs have artist tags."))
            } else {
                List(model.artists, id: \.self) { artist in
                    NavigationLink {
                        TrackListView(model: model, title: artist.name, tracks: model.tracks(byArtist: artist))
                    } label: {
                        HStack {
                            Text(artist.name).lineLimit(1)
                            Spacer()
                            Text(artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Artists")
    }
}

struct FoldersView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.folders.isEmpty {
                ContentUnavailableView("No folders yet", systemImage: "folder", description: Text("Add a folder of music in Sources."))
            } else {
                List(model.folders, id: \.self) { folder in
                    NavigationLink {
                        TrackListView(model: model, title: (folder.path as NSString).lastPathComponent, tracks: model.tracks(inFolder: folder))
                    } label: {
                        HStack {
                            Label((folder.path as NSString).lastPathComponent, systemImage: "folder")
                            Spacer()
                            Text("\(folder.trackCount)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .help(folder.path)
                    }
                }
            }
        }
        .navigationTitle("Folders")
    }
}

struct SourcesView: View {
    let model: AppModel
    let onAddFolder: () -> Void
    @State private var pendingRemoval: LibraryRoot?

    var body: some View {
        List {
            Section {
                ForEach(model.roots, id: \.id) { root in
                    HStack {
                        Label((root.displayPath as NSString).lastPathComponent, systemImage: "folder")
                        Spacer()
                        if root.status == .inaccessible {
                            Label("Not accessible", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(ZennoxTheme.warning)
                        }
                    }
                    .help(root.displayPath)
                    .contextMenu {
                        Button("Remove from Library", role: .destructive) { pendingRemoval = root }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { pendingRemoval = root }
                    }
                }
                Button(action: onAddFolder) { Label("Add Folder…", systemImage: "plus") }
            } header: {
                Text("On this device")
            } footer: {
                Text("Zennox reads only the folders you add. Removing a folder removes it from the library; your files are never changed or deleted.")
            }
            Section("Google Drive") {
                Text("Coming in the next build.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sources")
        .confirmationDialog("Remove this folder from the library?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), presenting: pendingRemoval) { root in
            Button("Remove from Library", role: .destructive) { model.remove(root) }
        } message: { _ in
            Text("Its songs leave the library, along with their favorites and playlist entries. The files stay where they are.")
        }
    }
}
#endif
