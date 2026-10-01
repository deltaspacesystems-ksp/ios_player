import SwiftUI
import UIKit

/// Entry point used by the VLC app: adds Lumen's extra features as one more tab.
public enum LumenKit {
    /// Called whenever Lumen is about to start audio, so the host can pause its own player.
    @MainActor public static var onWillPlay: (() -> Void)?

    @MainActor private static let state = LumenState()

    @MainActor public static func makeViewController() -> UIViewController {
        let vc = UIHostingController(rootView: LumenRoot(state: state))
        vc.tabBarItem = UITabBarItem(title: "Lumen", image: UIImage(systemName: "sparkles"), selectedImage: UIImage(systemName: "sparkles"))
        vc.title = "Lumen"
        Log.i("lumen", "Lumen tab created")
        return vc
    }

    /// Pauses Lumen's engine (used when the host starts playing).
    @MainActor public static func pause() { state.player.pause() }
}

@MainActor
final class LumenState {
    let player = Player()
    let library = Library()
    let mixes = MixStore()
    let shazam = ShazamService()
    let playlists = PlaylistStore()
}

struct LumenRoot: View {
    let state: LumenState
    @ObservedObject private var player: Player

    init(state: LumenState) {
        self.state = state
        _player = ObservedObject(wrappedValue: state.player)
    }

    var body: some View {
        LumenHub()
            .environmentObject(state.player)
            .environmentObject(state.player.clock)
            .environmentObject(state.player.analysis)
            .environmentObject(state.library)
            .environmentObject(state.mixes)
            .environmentObject(state.shazam)
            .environmentObject(state.playlists)
            .tint(player.cfg.accent)
            .task { await state.library.reload() }
    }
}

struct LumenHub: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: Library
    @EnvironmentObject var shazam: ShazamService
    @State private var showNow = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { AudioTab(embedded: true) } label: {
                        row("Library", "Artists, albums, tracks, genres", "music.note.list")
                    }
                    NavigationLink { PlaylistsTab(embedded: true) } label: {
                        row("Playlists & Mixes", "Mix editor with crossfade per transition", "rectangle.3.group")
                    }
                } header: { Text("Lumen player") } footer: {
                    Text("Crossfade, gapless playback, EQ, music haptics and the spectrum run on Lumen's own audio engine. Files are read from this app's Documents folder.")
                }

                Section("DJ & tools") {
                    Button { player.startDJ(pool: library.audio) } label: {
                        row("Start DJ", "Offline mixes by tempo, key and energy, with a voice", "sparkles")
                    }
                    .buttonStyle(.plain)
                    Button { Task { await shazam.listen(target: player.current, presenter: .list) } } label: {
                        row("Listen with Shazam", "Identify music through the microphone", "shazam.logo")
                    }
                    .buttonStyle(.plain)
                    Button { showNow = true } label: {
                        row("Now Playing", player.current?.title ?? "Nothing playing", "play.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(player.current == nil)
                }

                Section {
                    NavigationLink { SettingsView(embedded: true) } label: {
                        row("Lumen settings", "Crossfade, haptics, EQ, DJ, visualizer, appearance", "slider.horizontal.3")
                    }
                    NavigationLink { LogViewer() } label: {
                        row("Logs & diagnostics", "View and send logs", "doc.text.magnifyingglass")
                    }
                }
            }
            .navigationTitle("Lumen")
            .safeAreaInset(edge: .bottom) {
                if player.current != nil {
                    MiniPlayer()
                        .frame(height: 52)
                        .lGlass(Capsule())
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { showNow = true }
                }
            }
        }
        .sheet(isPresented: $showNow) { NowPlayingView() }
        .sheet(isPresented: Binding(get: { shazam.showSheet && shazam.presenter == .list }, set: { shazam.showSheet = $0 })) { ShazamSheet() }
    }

    private func row(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .contentShape(Rectangle())
    }
}
