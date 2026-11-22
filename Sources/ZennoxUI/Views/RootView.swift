#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import ZennoxCore

/// Sidebar + content (DESIGN.md §5). On iPhone the split view collapses to a navigation stack.
public struct RootView: View {
    @Bindable private var model: AppModel
    @State private var query = ""
    @State private var isPickingFolder = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Section("Library") {
                    ForEach([LibrarySection.songs, .albums, .artists, .folders]) { row($0) }
                }
                Section("For You") {
                    ForEach([LibrarySection.favorites, .recentlyAdded, .recentlyPlayed]) { row($0) }
                }
                Section { row(.sources) }
            }
            .navigationTitle("Zennox")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            #endif
        } detail: {
            NavigationStack {
                detail
                    .searchable(text: $query, prompt: "Songs, artists, albums")
                    .toolbar {
                        ToolbarItemGroup {
                            if model.isScanning { ProgressView().controlSize(.small) }
                            Button { model.rescanAll() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                                .disabled(model.isScanning || model.roots.isEmpty)
                                .keyboardShortcut("r", modifiers: [.command])
                            Button { isPickingFolder = true } label: { Label("Add Folder", systemImage: "plus") }
                                .keyboardShortcut("o", modifiers: [.command])
                        }
                    }
                    .safeAreaInset(edge: .bottom) { statusBar }
            }
        }
        .tint(ZennoxTheme.accent)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.addFolders(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { model.rescanAll() }
    }

    private func row(_ section: LibrarySection) -> some View {
        Label(section.title, systemImage: section.symbol).tag(section)  // non-optional: List(selection: Binding<T?>) matches tags of T
    }

    @ViewBuilder private var detail: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let results = model.search(query)
            TrackListView(model: model, title: "Search", tracks: results,
                          emptyTitle: "No results", emptyMessage: "Try a different song, artist or album.")
        } else if model.isEmpty {
            ContentUnavailableView {
                Label("Your music, your files", systemImage: "music.note.house")
            } description: {
                Text("Add a folder of music from this device. Zennox reads your files where they are and never copies or changes them.")
            } actions: {
                Button("Add Folder…") { isPickingFolder = true }.buttonStyle(.borderedProminent)
            }
        } else {
            switch model.section ?? .songs {
            case .songs: TrackListView(model: model, title: "Songs", tracks: model.songs, showsSort: true)
            case .albums: AlbumsView(model: model)
            case .artists: ArtistsView(model: model)
            case .folders: FoldersView(model: model)
            case .favorites:
                TrackListView(model: model, title: "Favorites", tracks: model.favorites,
                              emptyTitle: "No favorites yet", emptyMessage: "Tap the heart on any song.")
            case .recentlyAdded: TrackListView(model: model, title: "Recently Added", tracks: model.recentlyAdded)
            case .recentlyPlayed:
                TrackListView(model: model, title: "Recently Played", tracks: model.recentlyPlayed,
                              emptyTitle: "Nothing played yet", emptyMessage: "Playback arrives in the next build.")
            case .sources: SourcesView(model: model) { isPickingFolder = true }
            }
        }
    }

    @ViewBuilder private var statusBar: some View {
        if let message = model.statusMessage {
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
#endif
