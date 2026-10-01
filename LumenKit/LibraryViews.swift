import SwiftUI

// MARK: - Audio tab (Artists | Albums | Tracks | Genres)

struct AudioGroup: Hashable {
    enum Kind: String { case artist, album, genre }
    let kind: Kind
    let key: String
    let title: String
}

extension Library {
    func tracks(in g: AudioGroup) -> [Track] {
        let list: [Track]
        switch g.kind {
        case .artist: list = audio.filter { ($0.artist.isEmpty ? "Unknown artist" : $0.artist) == g.key }
        case .album: list = audio.filter { ($0.album.isEmpty ? "Unknown album" : $0.album) + "|" + $0.artist == g.key }
        case .genre: list = audio.filter { ($0.genre.isEmpty ? "Unknown genre" : $0.genre) == g.key }
        }
        return list.sorted { ($0.album, $0.title) < ($1.album, $1.title) }
    }
}

struct AudioTab: View {
    @EnvironmentObject var library: Library
    var embedded = false
    @AppStorage("lumen.audio.seg") private var seg = 2
    @State private var query = ""

    var body: some View {
        MaybeStack(embedded: embedded) {
            VStack(spacing: 0) {
                Picker("", selection: $seg) {
                    Text("Artists").tag(0)
                    Text("Albums").tag(1)
                    Text("Tracks").tag(2)
                    Text("Genres").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                Group {
                    if library.audio.isEmpty {
                        ContentUnavailableView("No music yet", systemImage: "music.note.list",
                            description: Text("Tap + to import files or add a folder that Lumen keeps scanning."))
                    } else {
                        switch seg {
                        case 0: ArtistsList(query: query)
                        case 1: AlbumsGrid(query: query)
                        case 3: GenresList(query: query)
                        default: TracksList(query: query)
                        }
                    }
                }
            }
            .navigationTitle("Audio")
            .searchable(text: $query)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ImportButton() } }
            .navigationDestination(for: AudioGroup.self) { g in
                CollectionDetail(group: g)
            }
        }
    }
}

struct ArtistsList: View {
    @EnvironmentObject var library: Library
    let query: String

    var body: some View {
        let groups = Dictionary(grouping: library.audio) { $0.artist.isEmpty ? "Unknown artist" : $0.artist }
        let names = groups.keys.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        List(names, id: \.self) { n in
            NavigationLink(value: AudioGroup(kind: .artist, key: n, title: n)) {
                HStack(spacing: 12) {
                    ThumbView(id: groups[n]?.first?.id, radius: 28).frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n)
                        Text("\(groups[n]?.count ?? 0) tracks").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

struct AlbumsGrid: View {
    @EnvironmentObject var library: Library
    let query: String

    var body: some View {
        let groups = Dictionary(grouping: library.audio) { ($0.album.isEmpty ? "Unknown album" : $0.album) + "|" + $0.artist }
        let keys = groups.keys.filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                ForEach(keys, id: \.self) { k in
                    let first = groups[k]?.first
                    let title = first.map { $0.album.isEmpty ? "Unknown album" : $0.album } ?? k
                    NavigationLink(value: AudioGroup(kind: .album, key: k, title: title)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ThumbView(id: first?.id, radius: 12)
                            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(first?.artist.isEmpty == false ? first!.artist : "Unknown artist")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }
}

struct GenresList: View {
    @EnvironmentObject var library: Library
    let query: String

    var body: some View {
        let groups = Dictionary(grouping: library.audio) { $0.genre.isEmpty ? "Unknown genre" : $0.genre }
        let names = groups.keys.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        List(names, id: \.self) { n in
            NavigationLink(value: AudioGroup(kind: .genre, key: n, title: n)) {
                HStack(spacing: 12) {
                    ThumbView(id: groups[n]?.first?.id, radius: 8).frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n)
                        Text("\(groups[n]?.count ?? 0) tracks").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

struct CollectionDetail: View {
    let group: AudioGroup
    @EnvironmentObject var library: Library

    var body: some View {
        let tracks = library.tracks(in: group)
        CollectionList(title: group.title, subtitle: "\(tracks.count) tracks", tracks: tracks, artworkID: tracks.first?.id)
    }
}

/// Header (artwork, Play / Shuffle) + track list, shared by album / artist / genre / playlist screens.
struct CollectionList: View {
    let title: String
    let subtitle: String
    let tracks: [Track]
    let artworkID: String?
    var onDelete: ((IndexSet) -> Void)?
    var onMove: ((IndexSet, Int) -> Void)?
    @EnvironmentObject var player: Player

    init(title: String, subtitle: String, tracks: [Track], artworkID: String?,
         onDelete: ((IndexSet) -> Void)? = nil, onMove: ((IndexSet, Int) -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.tracks = tracks
        self.artworkID = artworkID
        self.onDelete = onDelete
        self.onMove = onMove
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ThumbView(id: artworkID, radius: 16).frame(width: 190, height: 190)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                    Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        pill("Play", "play.fill", filled: true) { player.setQueue(tracks, start: 0, shuffled: false) }
                        pill("Shuffle", "shuffle", filled: false) {
                            player.setQueue(tracks, start: Int.random(in: 0..<max(1, tracks.count)), shuffled: true)
                        }
                    }
                    .disabled(tracks.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                    Button { player.setQueue(tracks, start: i) } label: { TrackRow(track: t, playing: player.current == t, showMenu: true) }
                        .buttonStyle(.plain)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
                .onDelete(perform: onDelete)
                .onMove(perform: onMove)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if onMove != nil { ToolbarItem(placement: .topBarTrailing) { EditButton() } } }
    }

    private func pill(_ text: String, _ icon: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(filled ? .white : Color.accentColor)
                .background(filled ? Color.accentColor : Color.accentColor.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct TracksList: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: Library
    let query: String

    private var items: [Track] {
        query.isEmpty ? library.audio : library.audio.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if !items.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        big("Play", "play.fill", filled: true) { player.setQueue(items, start: 0, shuffled: false) }
                        big("Shuffle", "shuffle", filled: false) { player.setQueue(items, start: Int.random(in: 0..<items.count), shuffled: true) }
                        big("DJ", "sparkles", filled: false) { player.startDJ(pool: library.audio) }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                }
            }
            Section {
                ForEach(items) { t in
                    Button {
                        if let i = items.firstIndex(of: t) { player.setQueue(items, start: i) }
                    } label: { TrackRow(track: t, playing: player.current == t, showMenu: true) }
                    .buttonStyle(.plain)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
            }
        }
        .listStyle(.plain)
    }

    private func big(_ text: String, _ icon: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(filled ? .white : Color.accentColor)
                .background(filled ? Color.accentColor : Color.accentColor.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
