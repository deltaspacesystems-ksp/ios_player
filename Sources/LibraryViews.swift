import SwiftUI

// MARK: - Video tab (VLC style: grid / list, sort, search)

enum VideoSort: String, CaseIterable, Identifiable {
    case name = "Name", duration = "Duration", added = "Date added"
    var id: String { rawValue }
}

struct VideoThumb: View {
    let id: String
    @State private var img: UIImage?

    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let img { Image(uiImage: img).resizable().scaledToFill() }
                else { Image(systemName: "film").font(.title2).foregroundStyle(.secondary) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: id) {
                if let c = ThumbStore.cached(id) { img = c; return }
                img = await Task.detached(priority: .utility) { ThumbStore.image(for: id) }.value
            }
    }
}

struct VideoCell: View {
    let track: Track

    var body: some View {
        let resume = PlaybackMemory.shared.resume(for: track.url) ?? 0
        let progress = track.duration > 0 ? min(1, Double(resume) / 1000 / track.duration) : 0
        VStack(alignment: .leading, spacing: 6) {
            VideoThumb(id: track.id)
                .overlay(alignment: .bottomTrailing) {
                    if track.duration > 0 {
                        Text(formatTime(track.duration))
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if progress > 0.01 {
                        GeometryReader { g in
                            Rectangle().fill(Color.accentColor).frame(width: g.size.width * progress, height: 3)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
            Text(track.title).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
            Text(track.url.pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct VideoTab: View {
    @EnvironmentObject var library: Library
    @Binding var videoTrack: Track?
    @AppStorage("lumen.video.grid") private var grid = true
    @AppStorage("lumen.video.sort") private var sortRaw = VideoSort.name.rawValue
    @State private var query = ""

    private var sort: VideoSort { VideoSort(rawValue: sortRaw) ?? .name }

    private var items: [Track] {
        let f = query.isEmpty ? library.videos : library.videos.filter { $0.title.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .name: return f.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .duration: return f.sorted { $0.duration > $1.duration }
        case .added: return f.sorted { $0.modified > $1.modified }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.videos.isEmpty {
                    ContentUnavailableView("No videos yet", systemImage: "film",
                        description: Text("Tap + to import videos or add a folder. MKV, AVI, WebM, MP4 and more are supported."))
                } else if grid {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 18) {
                            ForEach(items) { v in
                                Button { videoTrack = v } label: { VideoCell(track: v) }
                                    .buttonStyle(.plain)
                                    .contextMenu { menu(v) }
                            }
                        }
                        .padding(16)
                    }
                } else {
                    List(items) { v in
                        Button { videoTrack = v } label: {
                            HStack(spacing: 12) {
                                VideoThumb(id: v.id).frame(width: 120)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(v.title).font(.body).lineLimit(2)
                                    Text(formatTime(v.duration) + " · " + v.url.pathExtension.uppercased())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(v) }
                        .swipeActions { if library.canDelete(v) { Button("Delete", role: .destructive) { library.delete(v) } } }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Video")
            .searchable(text: $query)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sortRaw) {
                            ForEach(VideoSort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }
                    ImportButton()
                }
            }
        }
    }

    @ViewBuilder private func menu(_ v: Track) -> some View {
        Button("Play", systemImage: "play.fill") { videoTrack = v }
        Button("Mark as unplayed", systemImage: "arrow.counterclockwise") { PlaybackMemory.shared.setResume(nil, for: v.url) }
        if library.canDelete(v) { Button("Delete", systemImage: "trash", role: .destructive) { library.delete(v) } }
    }
}

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
    @AppStorage("lumen.audio.seg") private var seg = 2
    @State private var query = ""

    var body: some View {
        NavigationStack {
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
                    if library.audio.isEmpty && library.vlcAudio.isEmpty {
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
    @State private var vlcAudioTrack: Track?

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
            if !library.vlcAudio.isEmpty {
                Section("Other formats (played by VLC)") {
                    ForEach(library.vlcAudio) { t in
                        Button { vlcAudioTrack = t } label: { TrackRow(track: t, playing: false) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
        .fullScreenCover(item: $vlcAudioTrack) { t in
            VLCPlayerScreen(items: library.vlcAudio.map { VLCItem(url: $0.url, title: $0.title) },
                            start: library.vlcAudio.firstIndex(of: t) ?? 0, cfg: player.cfg)
        }
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
