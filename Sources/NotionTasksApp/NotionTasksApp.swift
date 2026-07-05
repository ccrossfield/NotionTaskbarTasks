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

/// The floating panel behind the quick-capture window and the shortcut recorder
/// (#34). Borderless and non-activating like `TaskPanel`, but able to become key
/// so its text field / key recorder gets input. `cancelOperation` (Esc,
/// ⌘-period) routes to `onCancel`.
private final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
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

    /// The real global-hotkey service (#34). Held so the shell can wire its
    /// fire action; the model drives its (re-)registration.
    private let hotKeyService: CarbonHotKeyService
    private let model: AppModel
    /// The quick-capture window's draft (#34), shared with `CaptureView`.
    private let captureModel = CaptureModel()

    override init() {
        let hotKeyService = CarbonHotKeyService()
        self.hotKeyService = hotKeyService
        self.model = AppModel(
            tokenStore: KeychainTokenStore(),
            cache: FileTaskCache(),
            preferences: UserDefaultsPreferences(),
            loginItem: MainAppLoginItem(),
            hotKeyService: hotKeyService,
            makeClient: { token in NotionClient(token: token, http: URLSession.shared) }
        )
        super.init()
    }

    private var statusItem: NSStatusItem?
    private var panel: TaskPanel?
    private var hostingView: PanelHostingView?
    // The quick-capture window (#34): a second floating panel, independent of
    // the status-icon panel. Built once and repositioned on each open.
    private var capturePanel: KeyPanel?
    private var captureHostingView: NSHostingView<AnyView>?
    /// The single most-recent discarded capture title (#34), restored on the
    /// next open. In-memory only, per the issue — never persisted to disk.
    private var lastDiscardedTitle: String?
    /// The full draft of the most-recent *failed* capture (#37): title plus the
    /// chip selections, so a transient failure loses nothing and the next open
    /// restores it for a one-tap retry. In-memory only, like `lastDiscardedTitle`.
    private var lastFailedDraft: TaskDraft?
    private var captureIsTearingDown = false
    // The shortcut recorder (#34), shown only while recording a new combination.
    private var recorderPanel: KeyPanel?
    private var recorderHostingView: NSHostingView<AnyView>?
    private var recorderIsTearingDown = false
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?

    // The feel-parity knobs (#20): chrome tuned to match the MenuBarExtra
    // window this shell replaces — menu material, continuous rounded corners,
    // a hairline gap below the menu bar, no popover arrow, no animation.
    private static let cornerRadius: CGFloat = 16
    private static let menuBarGap: CGFloat = 4

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

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

        // The two global hotkeys (#34, #39): wire the fire actions first, so the
        // very first press has somewhere to go, then register both persisted (or
        // default) combinations. Show-panel reuses togglePanel's open/close and
        // click-away semantics unchanged — the two surfaces don't interact (#34).
        hotKeyService.onFire = { [weak self] in self?.openCapture() }
        hotKeyService.onPanelFire = { [weak self] in self?.togglePanel() }
        model.registerHotKey()

        // Panel key handling seen before the responder chain. Esc dismisses the
        // panel like a menu — except an open rename/composer/search absorbs the
        // first Esc, closing that instead (#22/#28/#32). ⌘F opens the search row
        // (#32). cancelOperation (via `onCancel`) covers the Esc routes that
        // bypass this, e.g. ⌘-period.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // The recorder's first responder owns every key while it's up (#34).
            if self.recorderPanel?.isKeyWindow == true { return event }
            // The capture window handles its own Esc; other keys flow to its
            // title field. It must take precedence over the main panel below.
            if self.capturePanel?.isKeyWindow == true {
                if event.keyCode == 53 { self.dismissCapture(); return nil }
                // ⌘↵ (Return keyCode 36 / keypad Enter 76, command only): file
                // the task, flip it to In Progress, and launch Claude Code (#40).
                // Handled here rather than via a SwiftUI .keyboardShortcut on the
                // button, which doesn't reliably fire in a borderless
                // non-activating KeyPanel — the same reason Esc and ⌘F are caught
                // in this monitor. A plain Enter still falls through to the
                // field's .onSubmit(onCommit).
                if event.keyCode == 36 || event.keyCode == 76,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                    self.commitCaptureAndWork()
                    return nil
                }
                return event
            }
            guard let panel = self.panel, panel.isVisible, panel.isKeyWindow else { return event }
            // ⌘F (keyCode 3), command only: reveal and focus the search row.
            if event.keyCode == 3,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                self.model.openSearch()
                return nil
            }
            if event.keyCode == 53 { // Esc
                if !self.handleCancel() { panel.close() }
                return nil
            }
            // ⌘↵ (Return 36 / keypad Enter 76, command only) while searching:
            // work on the sole result in Claude Code (#44), the keyboard twin of
            // the row's terminal button — mirroring the capture window's ⌘↵
            // (#40). Plain Enter opens it in Notion via the field's .onSubmit
            // (#42); the ⌘ modifier suppresses .onSubmit, so this must be caught
            // here rather than in SwiftUI. Consumed whenever searching so a
            // 0-or-many-results ⌘↵ doesn't fall through to a beep.
            if event.keyCode == 36 || event.keyCode == 76,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               self.model.isSearching {
                if let task = self.model.soleVisibleTask() { self.workInClaudeCode(on: task) }
                return nil
            }
            // Type-ahead (#41): a plain printable key with nothing focused opens
            // the search row and seeds it with that character. The model owns
            // the precedence (no field focused, no ⌘/⌃) and swallows the key on
            // a hit so it isn't double-inserted once the field takes focus.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if self.model.beginTypeAheadSearch(characters: event.characters,
                                               commandDown: flags.contains(.command),
                                               controlDown: flags.contains(.control)) {
                return nil
            }
            return event
        }
    }

    /// One cancel policy for both Esc routes: an inline rename absorbs the
    /// first Esc (cancelling the edit, #28), then an open composer (#22), then
    /// an open search row (#32); otherwise the panel closes. Composer and search
    /// are mutually exclusive, so at most one of those two ever fires.
    private func handleCancel() -> Bool {
        if model.editingTaskID != nil {
            model.cancelEditing()
            return true
        }
        if model.isComposing {
            model.closeComposer()
            return true
        }
        if model.isSearching {
            model.closeSearch()
            return true
        }
        return false
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

    /// Give the app a standard Edit menu (#43). A manual AppKit lifecycle ships
    /// no main menu, so none of the standard editing key equivalents fire —
    /// ⌘A/⌘C/⌘V/⌘X/⌘Z were all dead in every text field, including paste in
    /// quick-capture. As an `.accessory` app this menu never shows in the system
    /// menu bar; only its key equivalents go live, matched against `mainMenu`
    /// whenever a panel is key and a field is first responder. Edit-only on
    /// purpose: no App/Quit submenu, so ⌘Q-to-quit isn't introduced by the back
    /// door (Quit stays the gear menu's job, #20).
    private func installEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
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
        let hosting = PanelHostingView(rootView: AnyView(
            ContentView(
                onRecordShortcut: { [weak self] in self?.beginRecordingHotKey(.quickCapture) },
                onRecordPanelShortcut: { [weak self] in self?.beginRecordingHotKey(.showPanel) },
                onWorkInClaudeCode: { [weak self] task in self?.workInClaudeCode(on: task) },
                onChooseWorkspace: { [weak self] in self?.chooseClaudeWorkspace() })
                .environmentObject(model)))
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

    // MARK: NSWindowDelegate (all three panels share this delegate)

    /// Key moving elsewhere is a click outside — dismiss, like a menu. Each
    /// panel has its own rule, so branch on which one resigned (#34).
    func windowDidResignKey(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if window === capturePanel {
            // A click away from the capture window dismisses it, remembering any
            // unsubmitted draft (#34).
            dismissCapture()
        } else if window === recorderPanel {
            endRecording() // clicking away cancels recording
        } else if window === panel {
            // Opening the capture window or recorder steals key from the main
            // panel; that must not dismiss it — the two surfaces don't interact.
            if capturePanel?.isVisible == true || recorderPanel?.isVisible == true { return }
            panel?.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Only the main panel needs teardown; the capture window and recorder
        // clean themselves up in their dismiss paths (#34).
        guard notification.object as? NSWindow === panel else { return }
        // Closing the panel is a click-away: commit any inline rename before
        // the field is torn down, so the edit isn't lost (#28). Esc has
        // already cleared the edit via handleCancel, so this is a no-op there.
        model.commitEditing()
        // A dismissed panel starts clean next open: drop any search (#32), so
        // reopening never shows a stale filter hiding most tasks.
        model.closeSearch()
        // A capture failure is surfaced while the panel is open; drop it on
        // close so the next open is clean unless a fresh capture failed since
        // (#34).
        model.clearCaptureError()
        statusItem?.button?.highlight(false)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    // MARK: Quick-capture window (#34)

    /// The hotkey fired: open the floating capture window, centred on the screen
    /// under the cursor. With no token stored there is nowhere to capture into,
    /// so open the main panel's token-entry screen instead. Pressing the hotkey
    /// again while the window is already up closes it (#38) — the same
    /// dismiss-and-remember-the-draft path as Esc or a click away.
    private func openCapture() {
        if case .needsToken = model.state {
            openPanel()
            return
        }
        if let capturePanel, capturePanel.isVisible {
            // Press-again-to-close (#38): reuse dismissCapture verbatim, so a
            // typed-but-unsubmitted title is remembered for the next open.
            dismissCapture()
            return
        }
        // Restore the full draft from a failed capture (#37) if there is one, so
        // a transient failure loses nothing; otherwise seed the view-aware
        // defaults and restore just the last discarded title over the top -
        // chip selections aren't remembered on a plain dismiss, only the title (#34).
        var draft: TaskDraft
        if let failed = lastFailedDraft {
            draft = failed
            lastFailedDraft = nil
        } else {
            draft = model.composerDraft()
            draft.title = lastDiscardedTitle ?? ""
        }
        captureModel.draft = draft
        captureModel.focusToken += 1
        let panel = capturePanel ?? makeCapturePanel()
        layout(panel, size: captureHostingView?.fittingSize ?? NSSize(width: 560, height: 120),
               verticalBias: 0.62)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Enter in the capture window: create the task optimistically and close at
    /// once (#34). The draft was submitted, not discarded, so forget it.
    private func commitCapture() {
        guard let capturePanel, capturePanel.isVisible, !captureIsTearingDown else { return }
        let draft = captureModel.draft
        guard !draft.trimmedTitle.isEmpty else { return }
        lastDiscardedTitle = nil
        lastFailedDraft = nil
        captureIsTearingDown = true
        capturePanel.orderOut(nil)
        captureIsTearingDown = false
        // Optimistic capture (#37): the provisional row already shows in the
        // menu; reconcile in the background. On a transient failure keep the
        // full draft so the next capture-window open restores it for a retry.
        Task { [weak self] in
            let outcome = await self?.model.captureTask(draft)
            if outcome == .transientFailure { self?.lastFailedDraft = draft }
        }
    }

    /// ⌘↵ or the capsule's terminal button (#40): file the task, flip it to In
    /// Progress, and launch Claude Code — launch instantly, reconcile the status
    /// in the background. The three actions can't all fire at once: the create is
    /// optimistic (a `temp-` row, no real page yet), so only the terminal launch
    /// is instant; the status flip rides on the create's success inside
    /// `captureTask(beginWorking:)`.
    private func commitCaptureAndWork() {
        guard let capturePanel, capturePanel.isVisible, !captureIsTearingDown else { return }
        let draft = captureModel.draft
        guard !draft.trimmedTitle.isEmpty else { return }
        // 1. Pre-flight iTerm2. If it isn't installed, don't lose the typed input:
        //    file it as a plain To Do capture (no launch, no status flip) and say
        //    why. commitCapture reads the live draft and tears the capsule down.
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.iTermBundleID) != nil else {
            commitCapture()
            presentITermMissingAlert()
            return
        }
        // 2. Dismiss the capsule at once — the draft was submitted, not discarded.
        lastDiscardedTitle = nil
        lastFailedDraft = nil
        captureIsTearingDown = true
        capturePanel.orderOut(nil)
        captureIsTearingDown = false
        // 3. Launch iTerm2 immediately with a title-only seed. The real page
        //    doesn't exist yet, and terminal Claude Code has no Notion MCP to open
        //    a URL anyway, so the seed carries no url (#40).
        let seed = ClaudeCodeLaunch.seed(title: draft.trimmedTitle, url: nil)
        let command = ClaudeCodeLaunch.shellCommand(
            workspaceDirectory: model.claudeWorkspaceDirectory, seed: seed)
        runAppleScript(ClaudeCodeLaunch.iTermScript(command: command))
        // 4. Capture and flip to In Progress in the background. A transient
        //    failure preserves the full draft for a retry (re-open, plain Enter),
        //    exactly like commitCapture; the terminal is already open and stays.
        Task { [weak self] in
            let outcome = await self?.model.captureTask(draft, beginWorking: true)
            if outcome == .transientFailure { self?.lastFailedDraft = draft }
        }
    }

    /// Esc or a click away: close the capture window, remembering a typed-but-
    /// unsubmitted title so the next open restores it (#34). Guarded so the
    /// resign-key that ordering-out itself triggers can't re-enter and clobber
    /// the remembered/forgotten title.
    private func dismissCapture() {
        guard let capturePanel, capturePanel.isVisible, !captureIsTearingDown else { return }
        let trimmed = captureModel.draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        lastDiscardedTitle = trimmed.isEmpty ? nil : trimmed
        captureIsTearingDown = true
        capturePanel.orderOut(nil)
        captureIsTearingDown = false
    }

    /// Build a borderless, non-activating, key-capable floating panel with the
    /// shared quick-capture chrome (#34): pop-up-menu level, joins all spaces,
    /// no animation, and a clear background so the shadow follows the rounded
    /// SwiftUI content the caller supplies (not the frosted `.menu` panel
    /// chrome). Behind both the capture window and the shortcut recorder.
    private func makeKeyPanel(size: NSSize, content: NSView,
                              onCancel: @escaping () -> Void) -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        panel.contentView = content
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
        panel.onCancel = onCancel
        return panel
    }

    /// Build the capture panel once and reuse it (#34). Its rounded material
    /// chrome is drawn by `CaptureView`.
    private func makeCapturePanel() -> KeyPanel {
        let hosting = NSHostingView(rootView: AnyView(
            CaptureView(onCommit: { [weak self] in self?.commitCapture() },
                        onCommitAndWork: { [weak self] in self?.commitCaptureAndWork() })
                .environmentObject(model)
                .environmentObject(captureModel)))
        let panel = makeKeyPanel(size: NSSize(width: 560, height: 120), content: hosting,
                                 onCancel: { [weak self] in self?.dismissCapture() })
        self.capturePanel = panel
        self.captureHostingView = hosting
        return panel
    }

    // MARK: Shortcut recorder (#34, #39)

    /// Which of the two hotkeys (#39) the recorder is currently recording for, so
    /// a captured combination routes to the right setter and the panel shows the
    /// right prompt. The recorder is a single shared surface, reused for both.
    private enum HotKeyTarget {
        case quickCapture, showPanel
        /// The prompt shown while recording this shortcut.
        var recorderPrompt: String {
            switch self {
            case .quickCapture: return "Press the new shortcut for quick-capture"
            case .showPanel: return "Press the new shortcut for show panel"
            }
        }
    }
    private var recordingTarget: HotKeyTarget = .quickCapture

    /// Show the recorder to record a new combination for `target` (#39), which
    /// listens for the next key-down and re-registers that hotkey. The recorder
    /// is reused across both targets, so its prompt is refreshed on each open.
    private func beginRecordingHotKey(_ target: HotKeyTarget) {
        recordingTarget = target
        let panel = recorderPanel ?? makeRecorderPanel()
        // Refresh the prompt for the target being recorded — the panel is reused.
        recorderHostingView?.rootView = AnyView(recorderRoot())
        if !panel.isVisible {
            layout(panel, size: recorderHostingView?.fittingSize ?? NSSize(width: 300, height: 160),
                   verticalBias: 0.5)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// A key-down reached the recorder: turn it into a `HotKey` and route it to
    /// the target being recorded (#39). An invalid press (a modifier on its own)
    /// leaves the recorder up to try again; so does a combination equal to the
    /// *other* hotkey — the two must never coincide, so a collision is ignored
    /// and the recorder keeps listening. A valid, non-colliding one is registered
    /// and the recorder closes.
    private func applyRecordedShortcut(_ event: NSEvent) {
        guard let key = HotKey(recording: event) else { return }
        switch recordingTarget {
        case .quickCapture:
            if key == model.panelHotKey { return } // collides with show-panel: keep listening
            model.setHotKey(key)
        case .showPanel:
            if key == model.hotKey { return } // collides with quick-capture: keep listening
            model.setPanelHotKey(key)
        }
        endRecording()
    }

    private func endRecording() {
        guard let recorderPanel, recorderPanel.isVisible, !recorderIsTearingDown else { return }
        recorderIsTearingDown = true
        recorderPanel.orderOut(nil)
        recorderIsTearingDown = false
    }

    /// The recorder's SwiftUI content, carrying the prompt for the current
    /// target. Rebuilt on each open so the prompt matches (#39).
    private func recorderRoot() -> some View {
        RecorderView(prompt: recordingTarget.recorderPrompt,
                     onCapture: { [weak self] event in self?.applyRecordedShortcut(event) },
                     onCancel: { [weak self] in self?.endRecording() })
    }

    private func makeRecorderPanel() -> KeyPanel {
        let hosting = NSHostingView(rootView: AnyView(recorderRoot()))
        let panel = makeKeyPanel(size: NSSize(width: 300, height: 160), content: hosting,
                                 onCancel: { [weak self] in self?.endRecording() })
        self.recorderPanel = panel
        self.recorderHostingView = hosting
        return panel
    }

    // MARK: Work on a task in Claude Code (#35)

    /// iTerm2's bundle id, for the installed-check.
    private static let iTermBundleID = "com.googlecode.iterm2"

    /// Launch iTerm2 in the workspace directory and run `claude` seeded with the
    /// task (#35), flipping the task to In Progress as work starts. iTerm2-only:
    /// if it isn't installed, alert rather than fail silently. The `cd`/`claude`
    /// failures surface in the terminal itself, so there's no app-side handling
    /// for those.
    private func workInClaudeCode(on task: NotionTask) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.iTermBundleID) != nil else {
            presentITermMissingAlert()
            return
        }
        Task { await model.beginWorking(taskID: task.id) }
        let seed = ClaudeCodeLaunch.seed(title: task.title, url: task.url)
        let command = ClaudeCodeLaunch.shellCommand(
            workspaceDirectory: model.claudeWorkspaceDirectory, seed: seed)
        runAppleScript(ClaudeCodeLaunch.iTermScript(command: command))
    }

    /// Run an AppleScript source string (#35). First use triggers the macOS
    /// "NotionTasks wants to control iTerm2" automation prompt (the plist carries
    /// NSAppleEventsUsageDescription); a denial or error is logged, not fatal.
    private func runAppleScript(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error { NSLog("Claude Code launch failed: \(error)") }
    }

    private func presentITermMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "iTerm2 isn’t installed"
        alert.informativeText = "“Work on in Claude Code” opens the task in iTerm2. Install iTerm2 from iterm2.com, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Present a folder chooser for the Claude workspace directory (#35), seeded
    /// to the current directory. A chosen folder is persisted via the model.
    private func chooseClaudeWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder “Work on in Claude Code” launches into."
        panel.directoryURL = URL(fileURLWithPath:
            (model.claudeWorkspaceDirectory as NSString).expandingTildeInPath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            model.setClaudeWorkspaceDirectory(url.path)
        }
    }

    /// Centre `panel` on the screen holding the mouse cursor (multi-monitor),
    /// biased vertically: 0.5 is dead centre, higher sits above centre like
    /// Spotlight (#34).
    private func layout(_ panel: NSPanel, size: NSSize, verticalBias: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let x = visible.midX - size.width / 2
        let y = visible.minY + visible.height * verticalBias - size.height / 2
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
