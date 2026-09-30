import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var shazam: ShazamService
    @EnvironmentObject var library: Library
    @State private var showNow = false
    @State private var videoTrack: Track?

    var body: some View {
        TabView {
            Tab("Songs", systemImage: "music.note") { SongsView() }
            Tab("Mixes", systemImage: "rectangle.3.group") { MixesView() }
            Tab("Videos", systemImage: "play.rectangle.fill") { VideosView(videoTrack: $videoTrack) }
            Tab("Settings", systemImage: "slider.horizontal.3") { SettingsView() }
        }
        .tint(player.cfg.accent)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer()
                .contentShape(Rectangle())
                .onTapGesture { if player.current != nil { showNow = true } }
        }
        .sheet(isPresented: $showNow) { NowPlayingView() }
        .sheet(isPresented: Binding(get: { shazam.showSheet && shazam.presenter == .list }, set: { shazam.showSheet = $0 })) { ShazamSheet() }
        .fullScreenCover(item: $videoTrack) { VideoScreen(track: $0) }
        .task { await library.reload() }
        .onAppear { applyWindowTint() }
        .onChange(of: player.cfg.accentHex) { applyWindowTint() }
    }

    private func applyWindowTint() {
        let c = UIColor(player.cfg.accent)
        for sc in UIApplication.shared.connectedScenes {
            (sc as? UIWindowScene)?.windows.forEach { $0.tintColor = c }
        }
    }
}

// MARK: - Shared bits

struct ImportButton: View {
    @EnvironmentObject var library: Library
    @State private var show = false
    @State private var pickFolder = false

    var body: some View {
        Menu {
            Button("Import Files…", systemImage: "doc.badge.plus") { pickFolder = false; show = true }
            Button("Add Folder…", systemImage: "folder.badge.plus") { pickFolder = true; show = true }
        } label: { Image(systemName: "plus") }
        .fileImporter(isPresented: $show, allowedContentTypes: pickFolder ? [.folder] : [.audio, .movie],
                      allowsMultipleSelection: !pickFolder) { r in
            guard case .success(let urls) = r else { return }
            if pickFolder { if let f = urls.first { Task { await library.addFolder(f) } } }
            else { Task { await library.importFiles(urls) } }
        }
    }
}

struct ArtworkView: View {
    var image: UIImage?
    var radius: CGFloat = 12
    var body: some View {
        // Clear square defines the layout; the image only fills it (never widens the parent).
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color.accentColor, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay { Image(systemName: "music.note").font(.title).foregroundStyle(.white.opacity(0.85)) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct Scrubber: View {
    var value: Double
    var total: Double
    var onSeek: (Double) -> Void
    @State private var dragging = false
    @State private var dragValue = 0.0

    var body: some View {
        GeometryReader { g in
            let frac = total > 0 ? min(1, max(0, (dragging ? dragValue : value) / total)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: g.size.width * frac)
            }
            .frame(height: dragging ? 14 : 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        dragValue = total * Double(min(1, max(0, v.location.x / g.size.width)))
                    }
                    .onEnded { _ in
                        onSeek(dragValue)
                        dragging = false
                    }
            )
            .animation(.snappy(duration: 0.2), value: dragging)
        }
        .frame(height: 28)
        .sensoryFeedback(.selection, trigger: dragging)
    }
}

// MARK: - Songs

struct SongsView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var shazam: ShazamService
    @EnvironmentObject var library: Library
    @State private var query = ""

    private var items: [Track] {
        query.isEmpty ? library.audio : library.audio.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.audio.isEmpty {
                    ContentUnavailableView("No music yet", systemImage: "music.note.list",
                        description: Text("Tap + to import files or add a folder (iCloud Drive / On My iPhone) that Lumen keeps scanning."))
                } else {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                Button { player.setQueue(items, start: 0, shuffled: false) } label: {
                                    Label("Play", systemImage: "play.fill")
                                        .frame(maxWidth: .infinity, minHeight: 50)
                                        .foregroundStyle(.white)
                                        .background(player.cfg.accent, in: Capsule())
                                }
                                Button { player.setQueue(items, start: Int.random(in: 0..<items.count), shuffled: true) } label: {
                                    Label("Shuffle", systemImage: "shuffle")
                                        .frame(maxWidth: .infinity, minHeight: 50)
                                        .foregroundStyle(player.cfg.accent)
                                        .background(player.cfg.accent.opacity(0.18), in: Capsule())
                                }
                                Button { player.startDJ(pool: library.audio) } label: {
                                    Label("DJ", systemImage: "sparkles")
                                        .frame(maxWidth: .infinity, minHeight: 50)
                                        .foregroundStyle(player.cfg.accent)
                                        .background(player.cfg.accent.opacity(0.18), in: Capsule())
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.body.weight(.semibold))
                            .disabled(items.isEmpty)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                        }
                        Section {
                            ForEach(items) { t in
                                Button {
                                    if let i = items.firstIndex(of: t) { player.setQueue(items, start: i) }
                                } label: { TrackRow(track: t, playing: player.current == t) }
                                .buttonStyle(.plain)
                                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                                .contextMenu {
                                    Button("Start DJ from here", systemImage: "sparkles") { player.startDJ(pool: library.audio, from: t) }
                                    Button("Identify with Shazam", systemImage: "shazam.logo") { Task { await shazam.identify(t, from: nil, presenter: .list) } }
                                    Button("Play Next", systemImage: "text.insert") { player.playNext(t) }
                                    Button("Add to Queue", systemImage: "text.append") { player.enqueue(t) }
                                    if library.canDelete(t) { Button("Delete", systemImage: "trash", role: .destructive) { library.delete(t) } }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Songs")
            .searchable(text: $query)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ImportButton() } }
        }
    }
}

struct TrackRow: View {
    let track: Track
    var playing: Bool
    var body: some View {
        HStack(spacing: 12) {
            ThumbView(id: track.id, radius: 8).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1).foregroundStyle(playing ? Color.accentColor : .primary)
                Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if playing { Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(Color.accentColor) }
            Text(formatTime(track.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Videos

struct VideosView: View {
    @EnvironmentObject var library: Library
    @Binding var videoTrack: Track?

    var body: some View {
        NavigationStack {
            Group {
                if library.videos.isEmpty {
                    ContentUnavailableView("No videos yet", systemImage: "film",
                        description: Text("Import .mp4 / .mov / .m4v files with +."))
                } else {
                    List(library.videos) { v in
                        Button { videoTrack = v } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.rectangle.fill").font(.title2)
                                    .frame(width: 50, height: 50)
                                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
                                VStack(alignment: .leading) {
                                    Text(v.title).lineLimit(2)
                                    Text(formatTime(v.duration)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions { if library.canDelete(v) { Button("Delete", role: .destructive) { library.delete(v) } } }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Videos")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ImportButton() } }
        }
    }
}

// MARK: - Mini player

struct MiniPlayer: View {
    @EnvironmentObject var player: Player
    @State private var drag: CGFloat = 0
    @State private var swipes = 0
    var body: some View {
        HStack(spacing: 10) {
            ThumbView(id: player.current?.id, radius: 7).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Not Playing").font(.subheadline.weight(.semibold)).lineLimit(1)
                if let a = player.current?.artist, !a.isEmpty { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title3) }
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 36)
            }
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3) }
        }
        .padding(.horizontal, 14)
        .buttonStyle(.plain)
        .offset(x: drag / 3)
        .opacity(1 - min(0.4, abs(drag) / 400))
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { drag = $0.translation.width }
                .onEnded { v in
                    if v.translation.width < -60 { player.next(); swipes += 1 }
                    else if v.translation.width > 60 { player.previous(); swipes += 1 }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = 0 }
                }
        )
        .sensoryFeedback(.impact(flexibility: .soft), trigger: swipes)
    }
}

