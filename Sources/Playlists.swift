import SwiftUI

struct Playlist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var trackIDs: [String] = []
}

struct PlaylistRef: Hashable { let id: UUID }
struct MixRef: Hashable { let id: UUID }

@MainActor
final class PlaylistStore: ObservableObject {
    @Published var playlists: [Playlist] = [] { didSet { save() } }

    private static var fileURL: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("lumen-playlists.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL),
           let p = try? JSONDecoder().decode([Playlist].self, from: d) { playlists = p }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(playlists) { try? d.write(to: Self.fileURL) }
    }

    @discardableResult
    func create(name: String, with track: Track? = nil) -> Playlist {
        let p = Playlist(name: name, trackIDs: track.map { [$0.id] } ?? [])
        playlists.append(p)
        Log.i("playlist", "Created '\(name)'")
        return p
    }

    func add(_ track: Track, to id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        if !playlists[i].trackIDs.contains(track.id) { playlists[i].trackIDs.append(track.id) }
    }

    func tracks(of p: Playlist, in library: Library) -> [Track] {
        let byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return p.trackIDs.compactMap { byID[$0] }
    }
}

// MARK: - Playlists tab (Playlists | Mixes), like VLC's Playlists tab

struct PlaylistsTab: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var mixes: MixStore
    @AppStorage("lumen.playlists.seg") private var seg = 0
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $seg) {
                    Text("Playlists").tag(0)
                    Text("Mixes").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                if seg == 0 { PlaylistsList() } else { MixesList() }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if seg == 0 { newName = ""; creating = true }
                        else { mixes.mixes.append(Mix(name: "New mix")) }
                    } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(for: PlaylistRef.self) { PlaylistDetail(id: $0.id) }
            .navigationDestination(for: MixRef.self) { MixEditorView(mixID: $0.id) }
            .alert("New playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Create") { if !newName.isEmpty { store.create(name: newName) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct PlaylistsList: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var library: Library
    @State private var renaming: Playlist?
    @State private var name = ""

    var body: some View {
        if store.playlists.isEmpty {
            ContentUnavailableView("No playlists", systemImage: "music.note.list",
                                   description: Text("Tap + to create one, or use “Add to Playlist” on any track."))
        } else {
            List {
                ForEach(store.playlists) { p in
                    NavigationLink(value: PlaylistRef(id: p.id)) {
                        HStack(spacing: 12) {
                            ThumbView(id: p.trackIDs.first, radius: 8).frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.body)
                                Text("\(p.trackIDs.count) tracks").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { store.playlists.removeAll { $0.id == p.id } }
                        Button("Rename") { renaming = p; name = p.name }.tint(.blue)
                    }
                }
            }
            .listStyle(.plain)
            .alert("Rename playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Save") {
                    if let r = renaming, let i = store.playlists.firstIndex(where: { $0.id == r.id }) { store.playlists[i].name = name }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }
}

struct PlaylistDetail: View {
    let id: UUID
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var library: Library

    var body: some View {
        if let i = store.playlists.firstIndex(where: { $0.id == id }) {
            let p = store.playlists[i]
            let tracks = store.tracks(of: p, in: library)
            CollectionList(title: p.name, subtitle: "\(tracks.count) tracks", tracks: tracks, artworkID: tracks.first?.id) {
                store.playlists[i].trackIDs.remove(atOffsets: $0)
            } onMove: {
                store.playlists[i].trackIDs.move(fromOffsets: $0, toOffset: $1)
            }
        } else {
            ContentUnavailableView("Playlist not found", systemImage: "questionmark.folder")
        }
    }
}

struct MixesList: View {
    @EnvironmentObject var store: MixStore

    var body: some View {
        if store.mixes.isEmpty {
            ContentUnavailableView("No mixes yet", systemImage: "rectangle.3.group",
                description: Text("Create a mix, arrange tracks and edit every transition. You can also save the current queue as a mix."))
        } else {
            List {
                ForEach(store.mixes) { m in
                    NavigationLink(value: MixRef(id: m.id)) {
                        HStack(spacing: 12) {
                            ThumbView(id: m.items.first?.trackID, radius: 8).frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name)
                                Text("\(m.items.count) tracks").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { store.mixes.remove(atOffsets: $0) }
            }
            .listStyle(.plain)
        }
    }
}
