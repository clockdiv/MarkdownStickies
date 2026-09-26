import SwiftUI
import MarkdownStickiesCore

@main
struct MarkdownStickiesIOSApp: App {
    @StateObject private var vault = VaultStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vault)
        }
    }
}
