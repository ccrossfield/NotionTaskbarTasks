import SwiftUI
import AppKit
import NotionTasksCore

/// The quick-capture window's draft (#34), owned by the shell (not view `@State`)
/// so the shell can read the live title at dismiss time - to remember a
/// discarded draft - and reset it on each open. The capsule binds to it.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var draft = TaskDraft()
    /// Bumped on each open to re-focus the title field, since the capsule view
    /// is built once and reused (so `onAppear` fires only the first time).
    @Published var focusToken = 0
}

/// The Spotlight-style quick-capture capsule (#34). Deliberately **not** the
/// frosted `.menu` chrome of the main panel: a large title field dominates,
/// with Priority/Category/Due rendered as one muted plain-text line beneath -
/// each value still fully clickable, opening the same pickers the composer's
/// chips use. Enter creates and closes the window (the shell does both); Esc or
/// a click away dismisses (also the shell). The due segment keeps the app's
/// urgency tint even in the muted row.
struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var capture: CaptureModel
    /// Enter/Return: create the task and close the window. The shell reads the
    /// live `capture.draft`, so this takes no argument.
    var onCommit: () -> Void
    /// ⌘↵ or the trailing terminal button (#40): file the task, flip it to In
    /// Progress, and launch Claude Code. Both routes run the shell's one handler.
    var onCommitAndWork: () -> Void = {}

    @FocusState private var titleFocused: Bool
    @State private var datePickerShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("Add a task…", text: $capture.draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .regular))
                    .focused($titleFocused)
                    .onSubmit(onCommit)
                addAndWorkButton
            }
            metadataLine
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))
        )
        .onAppear { focusSoon() }
        .onChange(of: capture.focusToken) { _, _ in focusSoon() }
    }

    /// Deferred a tick so the field is in the hierarchy before it takes key
    /// focus, as the composer and search fields do.
    private func focusSoon() {
        DispatchQueue.main.async { titleFocused = true }
    }

    /// The "add & work in Claude Code" button (#40): an accent-tinted terminal
    /// glyph with a faint ⌘↵ hint, mirroring the row's `workInClaudeButton`.
    /// Enabled only with a non-empty trimmed title, matching the ⌘↵ no-op on
    /// empty. Both this and ⌘↵ run the shell's one handler.
    private var addAndWorkButton: some View {
        Button(action: onCommitAndWork) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 16, weight: .medium))
                Text("⌘↵")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(capture.draft.trimmedTitle.isEmpty)
        .help("Add & work in Claude Code")
        .accessibilityLabel("Add & work in Claude Code")
    }

    /// The muted "P2 · Work · Today" line. Each value is a menu styled as plain
    /// text (not a button-chip) - visually quiet, fully functional.
    private var metadataLine: some View {
        HStack(spacing: 6) {
            valueMenu(current: capture.draft.priority, placeholder: "Priority",
                      options: model.schemaOptions.priorities) { capture.draft.priority = $0 }
            separator
            valueMenu(current: capture.draft.category, placeholder: "Category",
                      options: model.schemaOptions.categories) { capture.draft.category = $0 }
            separator
            dueMenu
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private var separator: some View {
        Text("·").font(.callout).foregroundStyle(.tertiary)
    }

    /// A single-select value menu (Priority / Category): the schema options plus
    /// None, checkmarking the current choice. Rendered as quiet plain text.
    private func valueMenu(current: String?, placeholder: String, options: [String],
                           set: @escaping (String?) -> Void) -> some View {
        Menu {
            Button("None") { set(nil) }
            Divider()
            ForEach(options, id: \.self) { option in
                Button {
                    set(option)
                } label: {
                    if current == option { Label(option, systemImage: "checkmark") }
                    else { Text(option) }
                }
            }
        } label: {
            Text(current ?? placeholder)
                .foregroundStyle(current == nil ? Color.secondary : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Due picks mirror the composer's (#22): None, Today, Tomorrow, Next
    /// Monday, and a graphical calendar for "Pick a date…" (#33). The label
    /// carries the app's relative wording and urgency tint.
    private var dueMenu: some View {
        Menu {
            Button("None") { capture.draft.dueDate = nil }
            Divider()
            Button("Today") { capture.draft.dueDate = Calendar.current.startOfDay(for: Date()) }
            Button("Tomorrow") { capture.draft.dueDate = ComposerDefaults.tomorrow(after: Date()) }
            Button("Next Monday") { capture.draft.dueDate = ComposerDefaults.nextMonday(after: Date()) }
            Divider()
            Button("Pick a date…") {
                if capture.draft.dueDate == nil {
                    capture.draft.dueDate = Calendar.current.startOfDay(for: Date())
                }
                DispatchQueue.main.async { datePickerShown = true }
            }
        } label: {
            dueLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $datePickerShown) {
            DatePicker("Due date",
                       selection: Binding(get: { capture.draft.dueDate ?? Date() },
                                          set: { capture.draft.dueDate = $0 }),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .frame(minWidth: 260)
        }
    }

    /// Reuses the app's relative wording and urgency tint by borrowing the
    /// `NotionTask` helpers on a throwaway task, so the capsule reads exactly
    /// like a row's due segment (#25).
    @ViewBuilder
    private var dueLabel: some View {
        if let due = capture.draft.dueDate {
            let probe = NotionTask(id: "", title: "", status: nil, dueDate: due)
            Text(probe.relativeDueText() ?? "Due")
                .foregroundStyle(DueColor.tint(for: probe.dueBucket()) ?? Color.primary)
        } else {
            Text("Due").foregroundStyle(.secondary)
        }
    }
}

/// The "record a new shortcut" surface (#34): a tiny panel that listens for the
/// next key-down and reports it up; Esc cancels. It captures through a
/// first-responder `NSView` (not a global event monitor), so it needs no
/// Input-Monitoring permission - the same reason the app uses Carbon for the
/// hotkey itself.
struct RecorderView: View {
    /// Names which shortcut is being recorded (#39), e.g. "Press the new
    /// shortcut for quick-capture". Defaulted so existing callers stay valid.
    var prompt: String = "Press the new shortcut"
    var onCapture: (NSEvent) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(prompt)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Esc to cancel")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(26)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))
        )
        // A zero-size first responder does the actual listening.
        .background(KeyRecorder(onCapture: onCapture, onCancel: onCancel)
            .frame(width: 0, height: 0))
    }
}

/// Bridges the key-capturing `NSView` into SwiftUI (#34).
private struct KeyRecorder: NSViewRepresentable {
    var onCapture: (NSEvent) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: KeyRecorderNSView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
    }
}

/// Becomes first responder in its (key) window and reports the next key-down.
/// Esc cancels; anything else is handed up to be validated into a `HotKey`.
final class KeyRecorderNSView: NSView {
    var onCapture: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
            return
        }
        onCapture?(event)
    }
}
