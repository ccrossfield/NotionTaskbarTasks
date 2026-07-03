import SwiftUI
import ServiceManagement
import NotionTasksCore

/// The real login-item service (#10): the app itself, registered with launchd
/// via `SMAppService`, which persists the setting system-side.
struct MainAppLoginItem: LoginItemService {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@main
struct NotionTasksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var model = AppModel(
        tokenStore: KeychainTokenStore(),
        cache: FileTaskCache(),
        preferences: UserDefaultsPreferences(),
        loginItem: MainAppLoginItem(),
        makeClient: { token in NotionClient(token: token, http: URLSession.shared) }
    )

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            // The label exists from launch (the panel doesn't), so this is
            // where the first fetch and the auto-refresh loop start (#7) —
            // the list stays current even when the panel is never opened,
            // keeping the attention count beside the icon honest (#10).
            let count = model.lateOrDueTodayCount()
            HStack(spacing: 3) {
                Image(systemName: "checklist")
                if count > 0 {
                    Text("\(count)")
                }
            }
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
