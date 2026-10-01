import SwiftUI
import UniformTypeIdentifiers

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
        .fileImporter(isPresented: $show, allowedContentTypes: pickFolder ? [.folder] : [.audio],
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
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay { Image(systemName: "music.note").font(.title).foregroundStyle(.white.opacity(0.85)) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct Scrubber: View {
    var value: Double
    var total: Double
    var fill: Color = .white
    var onSeek: (Double) -> Void
    @State private var dragging = false
    @State private var dragValue = 0.0

    var body: some View {
        GeometryReader { g in
            let frac = total > 0 ? min(1, max(0, (dragging ? dragValue : value) / total)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(fill).frame(width: g.size.width * frac)
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

struct TrackRow: View {
    let track: Track
    var playing: Bool
    var showMenu = false
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: Library
    @EnvironmentObject var shazam: ShazamService
    @EnvironmentObject var playlists: PlaylistStore

    var body: some View {
        HStack(spacing: 12) {
            ThumbView(id: track.id, radius: 8).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1).foregroundStyle(playing ? Color.accentColor : .primary)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if playing { Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(Color.accentColor) }
            Text(formatTime(track.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if showMenu {
                Menu {
                    Button("Play Next", systemImage: "text.insert") { player.playNext(track) }
                    Button("Add to Queue", systemImage: "text.append") { player.enqueue(track) }
                    Menu("Add to Playlist", systemImage: "text.badge.plus") {
                        ForEach(playlists.playlists) { p in Button(p.name) { playlists.add(track, to: p.id) } }
                        Button("New playlist…", systemImage: "plus") { playlists.create(name: track.title, with: track) }
                    }
                    Divider()
                    Button("Start DJ from here", systemImage: "sparkles") { player.startDJ(pool: library.audio, from: track) }
                    Button("Identify with Shazam", systemImage: "shazam.logo") { Task { await shazam.identify(track, from: nil, presenter: .list) } }
                    if library.canDelete(track) {
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { library.delete(track) }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 44).contentShape(Rectangle())
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let a = track.artist.isEmpty ? "Unknown artist" : track.artist
        return track.album.isEmpty ? a : a + " — " + track.album
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

/// Wraps content in a NavigationStack unless it is already shown inside the host's navigation.
struct MaybeStack<Content: View>: View {
    let embedded: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }
}
