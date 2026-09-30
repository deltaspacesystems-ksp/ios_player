import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var player = Player()
    @StateObject private var library = Library()
    @StateObject private var mixStore = MixStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(player.clock)
                .environmentObject(player.analysis)
                .environmentObject(mixStore)
                .tint(player.cfg.accent)
                .onOpenURL { url in Task { await library.importFiles([url]) } }
        }
    }
}
