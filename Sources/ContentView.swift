import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: Library
    @State private var showNow = false
    @State private var videoTrack: Track?

    var body: some View {
        TabView {
            Tab("Songs", systemImage: "music.note") { SongsView() }
            Tab("Videos", systemImage: "play.rectangle.fill") { VideosView(videoTrack: $videoTrack) }
            Tab("Settings", systemImage: "slider.horizontal.3") { SettingsView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer()
                .contentShape(Rectangle())
                .onTapGesture { if player.current != nil { showNow = true } }
        }
        .sheet(isPresented: $showNow) { NowPlayingView() }
        .fullScreenCover(item: $videoTrack) { VideoScreen(track: $0) }
        .task { await library.reload() }
    }
}

// MARK: - Shared bits

struct ImportButton: View {
    @EnvironmentObject var library: Library
    @State private var show = false
    var body: some View {
        Button { show = true } label: { Image(systemName: "plus") }
            .fileImporter(isPresented: $show, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { Task { await library.importFiles(urls) } }
            }
    }
}

struct ArtworkView: View {
    var image: UIImage?
    var radius: CGFloat = 12
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay { Image(systemName: "music.note").font(.title).foregroundStyle(.white.opacity(0.85)) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
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
                        description: Text("Tap + to import files, or drop them into Lumen via the Files app / Finder."))
                } else {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                Button { player.setQueue(items, start: 0, shuffled: false) } label: {
                                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent)
                                Button { player.setQueue(items, start: Int.random(in: 0..<items.count), shuffled: true) } label: {
                                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                            }
                            .disabled(items.isEmpty)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        }
                        Section {
                            ForEach(items) { t in
                                Button {
                                    if let i = items.firstIndex(of: t) { player.setQueue(items, start: i) }
                                } label: { TrackRow(track: t, playing: player.current == t) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Play Next", systemImage: "text.insert") { player.playNext(t) }
                                    Button("Add to Queue", systemImage: "text.append") { player.enqueue(t) }
                                    Button("Delete", systemImage: "trash", role: .destructive) { library.delete(t) }
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
            ArtworkView(image: track.artwork, radius: 8).frame(width: 50, height: 50)
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
                        .swipeActions { Button("Delete", role: .destructive) { library.delete(v) } }
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
    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(image: player.current?.artwork, radius: 7).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Not Playing").font(.subheadline.weight(.semibold)).lineLimit(1)
                if let a = player.current?.artist, !a.isEmpty { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 36)
            }
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3) }
        }
        .padding(.horizontal, 14)
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var player: Player
    var body: some View {
        NavigationStack {
            Form {
                Section("Crossfade") {
                    VStack(alignment: .leading) {
                        Text(player.crossfade < 0.5 ? "Off (gapless)" : "\(Int(player.crossfade)) seconds")
                        Slider(value: $player.crossfade, in: 0...12, step: 1)
                    }
                }
                Section {
                    Toggle("Music Haptics", isOn: $player.hapticsOn)
                    if player.hapticsOn {
                        VStack(alignment: .leading) {
                            Text("Strength")
                            Slider(value: $player.hapticStrength, in: 0.3...1.5)
                        }
                    }
                } header: { Text("Haptics") } footer: { Text("Feel the bass and beats through the Taptic Engine. iPhone only.") }
                Section("Equalizer") {
                    Picker("Preset", selection: $player.preset) {
                        ForEach(EQPreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Playback speed") {
                    Picker("Speed", selection: $player.speed) {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
