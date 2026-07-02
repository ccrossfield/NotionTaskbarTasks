import SwiftUI
import NotionTasksCore

@main
struct NotionTasksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var model = AppModel(
        tokenStore: KeychainTokenStore(),
        makeClient: { token in NotionClient(token: token, http: URLSession.shared) }
    )

    var body: some Scene {
        MenuBarExtra("Tasks", systemImage: "checklist") {
            ContentView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps the app menu-bar-only (no Dock icon, no main window).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
