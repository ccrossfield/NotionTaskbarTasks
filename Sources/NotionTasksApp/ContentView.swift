import SwiftUI
import NotionTasksCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tokenField = ""
    /// The quick-add draft (#22). View state: it exists only while composing,
    /// and is re-derived from `composerDraft()` every time the composer opens.
    @State private var draft = TaskDraft()
    /// Whether the compact due-date field is showing ("Pick a date…").
    @State private var showDueDateField = false
    @FocusState private var draftTitleFocused: Bool

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
                addButton
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
                    if model.isComposing {
                        composer
                    }
                    if let notice = model.createNotice {
                        createNoticeText(notice)
                    }
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

            // The schema didn't load (#14): the list stays visible, filtered
            // with the last-known-good facts; this says the filter options and
            // grouping may be stale. Amber, not red — the load itself worked.
            if let schemaWarning = model.schemaWarning {
                Text(schemaWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
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

    /// Quick-add (#22): a + in the header, left of refresh, shown only with a
    /// list loaded — there is nothing to add a task *to* on the other screens.
    /// It toggles the composer; opening re-derives the view-aware defaults, so
    /// a stale draft from the last composition never leaks in.
    @ViewBuilder
    private var addButton: some View {
        if case .loaded = model.state {
            Button {
                if model.isComposing {
                    model.closeComposer()
                } else {
                    draft = model.composerDraft()
                    showDueDateField = false
                    model.openComposer()
                }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New task")
            .accessibilityLabel("New task")
        }
    }

    /// The quick-add composer (#22): title plus the three quick fields, inline
    /// at the top of the list. Enter or Add creates (pessimistic — the row
    /// appears on success); Esc or Cancel discards. It sits inside the
    /// fixed-height loaded region, so opening it never resizes the panel — the
    /// list just loses a few rows of viewport while it's open.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("New task", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .focused($draftTitleFocused)
                .onSubmit(submitDraft)
                .onAppear {
                    // Deferred a tick: the field must be in the panel's view
                    // hierarchy before it can take key focus.
                    DispatchQueue.main.async { draftTitleFocused = true }
                }
            if showDueDateField {
                DatePicker("Due", selection: dueDateBinding, displayedComponents: .date)
                    .datePickerStyle(.stepperField)
                    .font(.caption)
            }
            composerFooter
            if let createError = model.createError {
                Text(createError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
        }
    }

    /// The composer footer (#23): quick fields and actions share one line when
    /// the panel is wide enough for the full chip labels, and fall back to the
    /// two-line layout when a long label (e.g. 👥 Friends & Family plus a due
    /// date) would collide with the buttons.
    private var composerFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                quickFields
                Spacer(minLength: 10)
                composerActions
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    quickFields
                    Spacer()
                }
                HStack {
                    Spacer()
                    composerActions
                }
            }
        }
    }

    /// The chips report their ideal width (`fixedSize`) so ViewThatFits
    /// measures the full labels — compressible chips would make the one-line
    /// candidate fit unconditionally and truncate.
    @ViewBuilder private var quickFields: some View {
        Group {
            quickFieldMenu("Priority", options: model.schemaOptions.priorities,
                           selection: $draft.priority)
            quickFieldMenu("Category", options: model.schemaOptions.categories,
                           selection: $draft.category)
            dueMenu
        }
        .font(.caption)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder private var composerActions: some View {
        Button("Cancel") { model.closeComposer() }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        Button {
            submitDraft()
        } label: {
            Group {
                if model.isCreating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Add")
                }
            }
            // The spinner is narrower than "Add"; a shared floor keeps the
            // footer's measured width stable mid-create.
            .frame(minWidth: 28)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(draft.trimmedTitle.isEmpty || model.isCreating)
    }

    /// A single-select quick-field menu (#22): the schema's options plus None.
    /// The label carries the choice, so a filled composer reads at a glance.
    private func quickFieldMenu(
        _ title: String, options: [String], selection: Binding<String?>
    ) -> some View {
        Menu(selection.wrappedValue ?? title) {
            Button("None") { selection.wrappedValue = nil }
            Divider()
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    if selection.wrappedValue == option {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        }
    }

    /// Due quick picks (#22): the fast-capture cases plus a compact date field
    /// for real deadlines — a calendar popover is too heavy for this panel,
    /// and the custom filter set the no-calendar precedent (#6).
    private var dueMenu: some View {
        Menu(dueLabel) {
            Button("None") {
                draft.dueDate = nil
                showDueDateField = false
            }
            Divider()
            Button("Today") { pickDue(Calendar.current.startOfDay(for: Date())) }
            Button("Tomorrow") { pickDue(ComposerDefaults.tomorrow(after: Date())) }
            Button("Next Monday") { pickDue(ComposerDefaults.nextMonday(after: Date())) }
            Divider()
            Button("Pick a date…") {
                if draft.dueDate == nil {
                    draft.dueDate = Calendar.current.startOfDay(for: Date())
                }
                showDueDateField = true
            }
        }
    }

    private func pickDue(_ date: Date) {
        draft.dueDate = date
        showDueDateField = false
    }

    private var dueLabel: String {
        guard let due = draft.dueDate else { return "Due" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "Due \(formatter.string(from: due))"
    }

    /// The date field needs a non-optional Date; while it is showing, an unset
    /// due date reads as today.
    private var dueDateBinding: Binding<Date> {
        Binding(get: { draft.dueDate ?? Calendar.current.startOfDay(for: Date()) },
                set: { draft.dueDate = $0 })
    }

    private func submitDraft() {
        guard !draft.trimmedTitle.isEmpty, !model.isCreating else { return }
        Task { await model.createTask(draft) }
    }

    /// The one-shot "created, but this view filters it out" notice (#22).
    /// Auto-dismisses: it is a confirmation, not an error to act on.
    private func createNoticeText(_ notice: String) -> some View {
        Text(notice)
            .font(.caption)
            .foregroundStyle(.secondary)
            .task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                model.clearCreateNotice()
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
                    Text(priority)
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
                title(for: task)
                metadata(for: task, showPriority: showPriority)
            }
            Spacer(minLength: 8)
            statusMenu(for: task)
        }
        .contextMenu {
            if task.webURL != nil {
                Button("Open in Notion") { openInNotion(task) }
            }
        }
    }

    /// Line 1: the title. Clicking it opens the task in Notion (#21), so
    /// fields the app doesn't edit are one click away; the row's context menu
    /// carries the same action for discoverability. A task with no URL (only
    /// possible from a pre-#21 cached snapshot) renders as plain text.
    @ViewBuilder
    private func title(for task: NotionTask) -> some View {
        if task.webURL != nil {
            Button {
                openInNotion(task)
            } label: {
                Text(task.title)
                    .lineLimit(2)
            }
            .buttonStyle(.plain)
            .help("Open in Notion")
        } else {
            Text(task.title)
                .lineLimit(2)
        }
    }

    /// The only open-target decision in the view: prefer the notion:// deep
    /// link when an app is installed to handle it (the Notion desktop app),
    /// otherwise the web URL in the default browser.
    private func openInNotion(_ task: NotionTask) {
        guard let web = task.webURL else { return }
        if let deep = task.notionAppURL,
           NSWorkspace.shared.urlForApplication(toOpen: deep) != nil {
            NSWorkspace.shared.open(deep)
        } else {
            NSWorkspace.shared.open(web)
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
                    Text(priority)
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
    /// A priority name beyond those three gets a neutral dot — the schema can
    /// grow options the app has never heard of (#15).
    private func colour(for priority: String) -> Color {
        switch priority {
        case "P0": return .red
        case "P1": return .orange
        case "P2": return .green
        default: return .gray
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
