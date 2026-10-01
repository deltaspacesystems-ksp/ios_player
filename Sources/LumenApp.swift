import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var player = Player()
    @StateObject private var library = Library()
    @StateObject private var mixStore = MixStore()
    @StateObject private var shazam = ShazamService()

    init() { Log.shared.startSession() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(player.clock)
                .environmentObject(player.analysis)
                .environmentObject(mixStore)
                .environmentObject(shazam)
                .tint(player.cfg.accent)
                .onOpenURL { url in Task { await library.importFiles([url]) } }
        }
    }
}
