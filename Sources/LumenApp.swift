import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var player = Player()
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(library)
                .tint(player.cfg.accent)
                .onOpenURL { url in Task { await library.importFiles([url]) } }
        }
    }
}
