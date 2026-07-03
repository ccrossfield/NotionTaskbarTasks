import SwiftUI
import NotionTasksCore

@main
struct NotionTasksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var model = AppModel(
        tokenStore: KeychainTokenStore(),
        cache: FileTaskCache(),
        preferences: UserDefaultsPreferences(),
        makeClient: { token in NotionClient(token: token, http: URLSession.shared) }
    )

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            // The label exists from launch (the panel doesn't), so this is
            // where the first fetch and the auto-refresh loop start (#7) —
            // the list stays current even when the panel is never opened.
            Image(systemName: "checklist")
                .task {
                    await model.start()
                    model.startPolling()
                }
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
