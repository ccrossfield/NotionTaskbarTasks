import SwiftUI
import NotionTasksCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tokenField = ""

    /// Fixed height for the loaded content region (controls + list). The
    /// MenuBarExtra window doesn't reliably resize to changing content, so a
    /// constant height gives it one size to adopt; the list scrolls inside it.
    private let loadedHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                header
                Spacer()
                staleBadge
                refreshButton
                settingsMenu
            }

            switch model.state {
            case .needsToken:
                tokenEntry
            case .loading:
                ProgressView("Loading tasks…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            case .loaded:
                VStack(alignment: .leading, spacing: 8) {
                    if model.isCustom {
                        customControls
                    }
                    taskList
                }
                .frame(height: loadedHeight)
            case .failed(let message):
                failure(message)
            }

            if let writeError = model.writeError {
                Text(writeError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // A refresh failed while a (possibly cached) list is showing: the
            // list stays put, this says why it may be stale.
            if let refreshError = model.refreshError {
                Text(refreshError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

        }
        .padding(12)
        .frame(width: 340)
    }

    /// The view picker doubles as the panel title: it shows the active view and
    /// switches on selection — the four presets (#5) plus a Custom entry (#6).
    /// Switching republishes, so the list below reflows with no manual refresh.
    private var header: some View {
        Menu {
            ForEach(Preset.allCases) { preset in
                Button {
                    model.selectPreset(preset)
                } label: {
                    if !model.isCustom && preset == model.preset {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
            }
            Divider()
            Button {
                model.enterCustom()
            } label: {
                if model.isCustom {
                    Label("Custom…", systemImage: "checkmark")
                } else {
                    Text("Custom…")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.activeTitle).font(.headline)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// A warning in the panel's top-right corner when the list is over a minute
    /// old — typically a cached snapshot whose background refresh hasn't landed
    /// (or failed). The timeline re-evaluates it while the panel stays open.
    private var staleBadge: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            if model.isStale(asOf: context.date) {
                Text("⚠️")
                    .help("Last refreshed over a minute ago — this list may be out of date")
                    .accessibilityLabel("Tasks may be out of date")
            }
        }
    }

    /// Manual refresh (#18): an icon button in the panel's top-right corner,
    /// shown only with a list loaded — the failure view has its own "Try again"
    /// and the token-entry screen has nothing to refresh. While a fetch is in
    /// flight the button is disabled and a small spinner takes the icon's place;
    /// the list itself stays visible behind it.
    @ViewBuilder
    private var refreshButton: some View {
        if case .loaded = model.state {
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing)
            .help("Refresh")
            .accessibilityLabel("Refresh")
        }
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
        let grouped = model.isGrouped
        let emptyMessage = model.isCustom
            ? "No tasks match this filter."
            : "Nothing in \(model.activeTitle) right now."
        // Always scroll inside the fixed region set in `body`. The MenuBarExtra
        // window doesn't reliably resize to changing content, so a self-sizing
        // list gets clipped by a too-small window and its lower rows vanish. A
        // fixed panel height with the list scrolling inside keeps every row
        // reachable — visible for short lists, scrollable for long ones.
        return Group {
            if groups.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    listContent(groups, grouped: grouped)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// The rows themselves, shared by the scrolling and non-scrolling branches.
    /// A collapsed group (#19) keeps its header and folds its rows away; flat
    /// presets have no headers, so nothing there can collapse.
    @ViewBuilder
    private func listContent(_ groups: [TaskGroup], grouped: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.priority) { group in
                if grouped {
                    sectionHeader(group)
                }
                if !grouped || !model.isCollapsed(group.priority) {
                    ForEach(group.tasks) { task in
                        row(for: task, showPriority: !grouped)
                            .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    /// The custom view's controls (#6): one "Filter" menu (with a submenu per
    /// field) and one "Sort" menu. Collapsing everything into two menus keeps the
    /// narrow menu-bar panel uncluttered. Every option list is schema-derived.
    private var customControls: some View {
        let query = model.customQuery
        let options = model.schemaOptions
        return HStack(spacing: 10) {
            Menu {
                filterSubmenu("Status", options: options.statuses, selected: query.statuses) {
                    var q = query; q.statuses = $0; model.updateCustom(q)
                }
                filterSubmenu("Category", options: options.categories, selected: query.categories) {
                    var q = query; q.categories = $0; model.updateCustom(q)
                }
                filterSubmenu("Priority", options: options.priorities, selected: query.priorities) {
                    var q = query; q.priorities = $0; model.updateCustom(q)
                }
                filterSubmenu("WorkType", options: options.workTypes, selected: query.workTypes) {
                    var q = query; q.workTypes = $0; model.updateCustom(q)
                }
                dateSubmenu("Due date", value: query.dueDate) {
                    var q = query; q.dueDate = $0; model.updateCustom(q)
                }
                dateSubmenu("Start from", value: query.startFrom) {
                    var q = query; q.startFrom = $0; model.updateCustom(q)
                }
                Divider()
                Button("Clear filters") { model.updateCustom(query.cleared()) }
                    .disabled(!query.isFiltering)
            } label: {
                Label("Filter", systemImage: query.isFiltering
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }

            Menu {
                ForEach(SortField.allCases, id: \.self) { field in
                    Button {
                        var q = query; q.sortField = field; model.updateCustom(q)
                    } label: {
                        if field == query.sortField {
                            Label(field.title, systemImage: "checkmark")
                        } else {
                            Text(field.title)
                        }
                    }
                }
                Divider()
                Button {
                    var q = query; q.ascending.toggle(); model.updateCustom(q)
                } label: {
                    Label(query.ascending ? "Ascending" : "Descending",
                          systemImage: query.ascending ? "arrow.up" : "arrow.down")
                }
            } label: {
                Label("Sort: \(query.sortField.title)",
                      systemImage: query.ascending ? "arrow.up" : "arrow.down")
            }

            Spacer()
        }
        .font(.caption)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// A multi-select filter submenu: each schema option toggles in/out of the
    /// set; the label carries the count when any are chosen.
    private func filterSubmenu(
        _ title: String, options: [String], selected: Set<String>,
        update: @escaping (Set<String>) -> Void
    ) -> some View {
        Menu(selected.isEmpty ? title : "\(title) (\(selected.count))") {
            ForEach(options, id: \.self) { option in
                Button {
                    var next = selected
                    if next.contains(option) { next.remove(option) } else { next.insert(option) }
                    update(next)
                } label: {
                    if selected.contains(option) {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        }
    }

    /// A single-select date-filter submenu (Any / Today or earlier / … ).
    private func dateSubmenu(
        _ title: String, value: DateFilter, update: @escaping (DateFilter) -> Void
    ) -> some View {
        Menu("\(title): \(value.title)") {
            ForEach(DateFilter.allCases, id: \.self) { option in
                Button {
                    update(option)
                } label: {
                    if option == value {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        }
    }

    /// A priority group's header, and the control that folds it (#19): the
    /// whole row is one full-width plain button — no precision chevron target
    /// in a 340px panel. The leading chevron carries the affordance; a
    /// collapsed header says how many rows it is hiding. No animation: the
    /// panel should feel instant.
    private func sectionHeader(_ group: TaskGroup) -> some View {
        let collapsed = model.isCollapsed(group.priority)
        return Button {
            model.toggleCollapsed(group.priority)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                if let priority = group.priority {
                    Circle()
                        .fill(colour(for: priority))
                        .frame(width: 7, height: 7)
                    Text(priority.rawValue)
                } else {
                    Text("No priority")
                }
                if collapsed {
                    Text("(\(group.tasks.count))")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(group.priority == nil ? Color.secondary : Color.primary)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? "Expand group" : "Collapse group")
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

    /// The auto-refresh cadence options offered in settings (#7): label + seconds.
    private static let refreshIntervals: [(title: String, seconds: TimeInterval)] = [
        ("Every minute", 60), ("Every 5 minutes", 300), ("Every 15 minutes", 900),
    ]

    /// In the header since the footer's deletion (#20). Quit moved to the menu
    /// bar icon's right-click menu; the last-fetched clock (#7) lives here as a
    /// passive first line — the stale badge still carries the warning role.
    private var settingsMenu: some View {
        Menu {
            if let lastRefreshed = model.lastRefreshed {
                Text("Updated \(lastRefreshed.formatted(date: .omitted, time: .shortened))")
                Divider()
            }
            Button {
                model.setLaunchAtLogin(!model.launchAtLogin)
            } label: {
                if model.launchAtLogin {
                    Label("Launch at login", systemImage: "checkmark")
                } else {
                    Text("Launch at login")
                }
            }
            Menu("Auto-refresh") {
                ForEach(Self.refreshIntervals, id: \.seconds) { option in
                    Button {
                        model.setAutoRefreshInterval(option.seconds)
                    } label: {
                        if model.autoRefreshInterval == option.seconds {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func connect() {
        let token = tokenField
        tokenField = ""
        Task { await model.submit(token: token) }
    }
}
