import AppKit
import SwiftUI
import Combine
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

/// The panel window (#20). Borderless and non-activating — opening it must not
/// yank focus from whatever app is frontmost — but able to become key, because
/// a non-activating panel silently refuses key status by default and the token
/// `SecureField` needs keyboard input. Esc closes it like a menu.
private final class TaskPanel: NSPanel {
    /// Gives the shell first refusal on a cancel: returns true when it was
    /// consumed (an open composer closes instead of the panel, #22), false to
    /// close like a menu.
    var onCancel: (() -> Bool)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        if onCancel?() == true { return }
        close()
    }
}

/// Reports SwiftUI content-size changes upward so the window can follow:
/// state transitions (token entry ↔ loaded ↔ failed, error captions coming
/// and going) change the panel's height while it is open.
private final class PanelHostingView: NSHostingView<AnyView> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @objc required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The AppKit shell (#20): an `NSStatusItem` owned here instead of a SwiftUI
/// `MenuBarExtra` scene, because `MenuBarExtra` cannot tell right-click from
/// left-click. Left-click toggles the panel hosting the existing `ContentView`;
/// right-click shows a menu with Quit. Introspection into `MenuBarExtra`'s
/// private status item was considered and rejected as fragile (issue #20).
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// `NSApplication.delegate` is unsafe-unretained; something must own this.
    private static let shared = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = shared
        app.run()
    }

    private let model = AppModel(
        tokenStore: KeychainTokenStore(),
        cache: FileTaskCache(),
        preferences: UserDefaultsPreferences(),
        loginItem: MainAppLoginItem(),
        makeClient: { token in NotionClient(token: token, http: URLSession.shared) }
    )

    private var statusItem: NSStatusItem?
    private var panel: TaskPanel?
    private var hostingView: PanelHostingView?
    private var cancellables: Set<AnyCancellable> = []
    private var escMonitor: Any?
    private var outsideClickMonitor: Any?

    // The feel-parity knobs (#20): chrome tuned to match the MenuBarExtra
    // window this shell replaces — menu material, continuous rounded corners,
    // a hairline gap below the menu bar, no popover arrow, no animation.
    private static let cornerRadius: CGFloat = 16
    private static let menuBarGap: CGFloat = 4

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "checklist",
                                   accessibilityDescription: "Notion Tasks")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        // The status item exists from launch (the panel doesn't), so this is
        // where the first fetch and the auto-refresh loop start (#7) — the
        // list stays current even when the panel is never opened, keeping the
        // attention count beside the icon honest (#10).
        Task {
            await model.start()
            model.startPolling()
        }

        // Every state change re-derives the count. receive(on:) defers past
        // @Published's willSet emission, so the model reads post-assignment.
        model.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)

        // Esc dismisses the panel like a menu — except an open composer
        // absorbs the first Esc, closing the draft instead (#22). This
        // monitor sees the key before the responder chain; cancelOperation
        // (via `onCancel`) covers the routes that bypass it, e.g. ⌘-period.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, let panel = self.panel, panel.isVisible else {
                return event
            }
            if !self.handleCancel() {
                panel.close()
            }
            return nil
        }
    }

    /// One cancel policy for both Esc routes: an open composer consumes the
    /// cancel; otherwise the panel closes (#22).
    private func handleCancel() -> Bool {
        guard model.isComposing else { return false }
        model.closeComposer()
        return true
    }

    /// The count beside the icon (#10): open tasks late or due today.
    private func updateBadge() {
        guard let button = statusItem?.button else { return }
        let count = model.lateOrDueTodayCount()
        button.title = count > 0 ? " \(count)" : ""
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuitMenu()
        } else {
            togglePanel()
        }
    }

    /// Right-click (#20): a menu, not the panel. The menu is attached only for
    /// the duration of the click — a persistent `statusItem.menu` would
    /// hijack left-click too. Launch-at-login joins this menu later (#10).
    private func showQuitMenu() {
        panel?.close()
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Notion Tasks",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func togglePanel() {
        if let panel, panel.isVisible {
            panel.close()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        let panel = self.panel ?? makePanel()
        layoutPanel(panel)
        // The icon stays lit while the panel is open, like a menu's title.
        statusItem?.button?.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        // A click delivered to any other app means "clicked outside": close.
        // Key-window resignation catches most of these; this catches the rest
        // (clicks that don't move key status, e.g. on another status item).
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.panel?.close()
        }
    }

    /// Build once, reuse across opens: keeps SwiftUI view state (the token
    /// field's draft) and spares a hosting-view rebuild per click.
    private func makePanel() -> TaskPanel {
        let hosting = PanelHostingView(rootView: AnyView(ContentView().environmentObject(model)))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.onSizeChange = { [weak self] in
            // Deferred: invalidation arrives mid-layout, and setFrame from
            // inside a layout pass re-enters it.
            DispatchQueue.main.async {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.layoutPanel(panel)
            }
        }

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        let panel = TaskPanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.handleCancel() ?? false }

        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    /// Attach the panel directly beneath the icon, centred and clamped to the
    /// screen edge, top-anchored so content growth extends downward.
    private func layoutPanel(_ panel: NSPanel) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let size = hostingView?.fittingSize ?? panel.frame.size
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(origin: .zero, size: size)
        var x = iconFrame.midX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        let y = iconFrame.minY - Self.menuBarGap - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                       display: true)
    }

    // MARK: NSWindowDelegate (the panel)

    /// Key moving elsewhere is a click outside — dismiss, like a menu.
    func windowDidResignKey(_ notification: Notification) {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
