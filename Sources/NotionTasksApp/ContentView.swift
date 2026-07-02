import SwiftUI
import NotionTasksCore

/// Carries the task list's natural content height up to the view so the panel
/// can size to it. A `ScrollView` reports a tiny ideal height, so without this
/// the `MenuBarExtra` window collapses to less than one row.
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tokenField = ""
    @State private var listHeight: CGFloat = 0

    /// Cap the list before it scrolls, so the panel never fills the screen.
    private let maxListHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch model.state {
            case .needsToken:
                tokenEntry
            case .loading:
                ProgressView("Loading tasks…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            case .loaded:
                taskList
            case .failed(let message):
                failure(message)
            }

            if let writeError = model.writeError {
                Text(writeError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .task { await model.start() }
    }

    /// The preset picker doubles as the panel title: it shows the active preset
    /// and switches on selection (#5). Switching republishes `model.preset`, so
    /// the list below reflows immediately with no manual refresh.
    private var header: some View {
        Menu {
            ForEach(Preset.allCases) { preset in
                Button {
                    model.selectPreset(preset)
                } label: {
                    if preset == model.preset {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.preset.title).font(.headline)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a Notion internal integration token to connect. It's stored in your Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("ntn_…", text: $tokenField)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
                .disabled(tokenField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// The active preset's list (#4/#5). Grouped presets (Pivotal, Home) render
    /// P0 / P1 / P2 / no-priority section headers, so their rows drop the own
    /// priority badge (`showPriority: false`); flat presets (Late or due today,
    /// All open) are one headerless list that keeps the per-row badge, since
    /// priority isn't otherwise shown.
    private var taskList: some View {
        let groups = model.groups()
        let grouped = model.preset.isGrouped
        return Group {
            if groups.isEmpty {
                Text("Nothing in \(model.preset.title) right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.priority) { group in
                            if grouped {
                                sectionHeader(group.priority)
                            }
                            ForEach(group.tasks) { task in
                                row(for: task, showPriority: !grouped)
                                    .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                    })
                }
                .frame(height: min(listHeight, maxListHeight))
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            }
        }
    }

    private func sectionHeader(_ priority: Priority?) -> some View {
        HStack(spacing: 5) {
            if let priority {
                Circle()
                    .fill(colour(for: priority))
                    .frame(width: 7, height: 7)
                Text(priority.rawValue)
            } else {
                Text("No priority")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(priority == nil ? Color.secondary : Color.primary)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(for task: NotionTask, showPriority: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 8) {
            completeButton(for: task)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .lineLimit(2)
                metadata(for: task, showPriority: showPriority)
            }
            Spacer(minLength: 8)
            statusMenu(for: task)
        }
    }

    /// One-click complete: sets the task to Done, reusing the #3 write path.
    /// Shows filled when already Done.
    private func completeButton(for task: NotionTask) -> some View {
        let isDone = task.status == "Done"
        return Button {
            Task { await model.setStatus(taskID: task.id, to: "Done") }
        } label: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? Color.secondary : Color.primary)
        }
        .buttonStyle(.plain)
        .help(isDone ? "Done" : "Mark done")
        .accessibilityLabel(isDone ? "Done" : "Mark done")
    }

    /// Line 2: Priority · Due date · Category, with absent fields omitted so
    /// there are no stray separators. Renders nothing when all are absent.
    /// `showPriority` is false in grouped views, where the header carries it.
    @ViewBuilder
    private func metadata(for task: NotionTask, showPriority: Bool) -> some View {
        // Due and category are plain text; join them so separators only appear
        // between present segments.
        let textSegments = [task.relativeDueText(), task.category].compactMap { $0 }
        let withPriority = showPriority && task.priority != nil
        if withPriority || !textSegments.isEmpty {
            HStack(spacing: 5) {
                if withPriority, let priority = task.priority {
                    Circle()
                        .fill(colour(for: priority))
                        .frame(width: 7, height: 7)
                    Text(priority.rawValue)
                    if !textSegments.isEmpty { Text("·") }
                }
                if !textSegments.isEmpty {
                    Text(textSegments.joined(separator: " · "))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The only colour in the list: P0 red, P1 amber, P2 green (ADR-0002).
    private func colour(for priority: Priority) -> Color {
        switch priority {
        case .p0: return .red
        case .p1: return .orange
        case .p2: return .green
        }
    }

    private func statusMenu(for task: NotionTask) -> some View {
        Menu {
            ForEach(NotionConfig.selectableStatuses, id: \.self) { state in
                Button(state) {
                    Task { await model.setStatus(taskID: task.id, to: state) }
                }
            }
        } label: {
            Text(task.status ?? "Set status")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Try again") { Task { await model.refresh() } }
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") { Task { await model.refresh() } }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.callout)
    }

    private func connect() {
        let token = tokenField
        tokenField = ""
        Task { await model.submit(token: token) }
    }
}
