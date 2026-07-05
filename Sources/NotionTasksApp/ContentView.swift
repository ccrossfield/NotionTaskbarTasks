import SwiftUI
import NotionTasksCore

struct ContentView: View {
    /// Opens the shell's quick-capture shortcut recorder (#34). The gear menu
    /// triggers it; recording lives in the shell (AppKit), not the view.
    var onRecordShortcut: () -> Void = {}
    /// Opens the shell's show-panel shortcut recorder (#39), the second hotkey.
    var onRecordPanelShortcut: () -> Void = {}
    /// Launches iTerm2 + `claude` for a task (#35). The shell owns the
    /// AppleScript launch and the iTerm2-missing alert; the view just invokes it.
    var onWorkInClaudeCode: (NotionTask) -> Void = { _ in }
    /// Opens a folder chooser for the Claude workspace directory (#35). NSOpenPanel
    /// lives in the shell (AppKit), not the view.
    var onChooseWorkspace: () -> Void = {}

    @EnvironmentObject private var model: AppModel
    /// Honour Reduce Motion (#36): with it on, the completion tick's bounce and
    /// the row's fade/collapse are skipped in favour of a plain instant cut.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The task row the pointer is over (#35): its trailing controls (the
    /// Claude-Code launch icon and the actions menu) fade in on hover.
    @State private var hoveredRowID: String?
    @State private var tokenField = ""
    /// The quick-add draft (#22). View state: it exists only while composing,
    /// and is re-derived from `composerDraft()` every time the composer opens.
    @State private var draft = TaskDraft()
    /// Whether the compact due-date field is showing ("Pick a date…").
    @State private var showDueDateField = false
    @FocusState private var draftTitleFocused: Bool
    /// Keyboard focus for the inline rename field (#28). Only one row edits at
    /// a time (the model holds a single `editingTaskID`), so one flag suffices.
    @FocusState private var editingFocused: Bool
    /// Keyboard focus for the header search field (#32).
    @FocusState private var searchFocused: Bool
    /// The task whose "Pick a date…" calendar popover is open (#33), or nil.
    /// Keyed by ID so only the matching row presents it, anchored to that row.
    @State private var datePickerTaskID: String?
    /// The date the open calendar popover is bound to (#33). Seeded to the
    /// task's current due date when the popover opens.
    @State private var draftDueDate = Date()

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
                searchButton
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
                    if model.isSearching {
                        searchField
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

            // A task captured via the global hotkey (#34) failed to reach Notion
            // while the panel was shut; surface it now, on this open, with the
            // same red-banner convention as writeError. Cleared when the panel
            // closes, so a later open is clean unless a fresh capture has failed.
            if let captureError = model.captureError {
                Text(captureError)
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
        // Not .borderlessButton like the other menus: that style draws its own
        // indicator arrow beside the custom chevron (two arrows on one title)
        // and ignores .menuIndicator(.hidden). The custom trailing chevron is
        // the sole affordance here.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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

    /// Search (#32): a magnifying glass beside the +, shown only with a list
    /// loaded — there's nothing to search on the other screens. It toggles the
    /// search row and tints while that row is open, so the state reads at a
    /// glance. Opening it collapses the composer (they share the row below the
    /// header); the model enforces that.
    @ViewBuilder
    private var searchButton: some View {
        if case .loaded = model.state {
            Button {
                model.toggleSearch()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isSearching ? Color.accentColor : Color.primary)
            .help("Search tasks")
            .accessibilityLabel("Search tasks")
        }
    }

    /// The search row (#32): a title filter over the active view, inline below
    /// the header like the composer. Auto-focused on open; live-filters as you
    /// type (the field writes straight to the model, which reflows `groups()`).
    /// The trailing ✕ clears without closing; Esc closes (via the shell's Esc
    /// monitor, as the rename field does). Sits in the fixed-height loaded
    /// region, so opening it never resizes the panel.
    private var searchField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search tasks", text: Binding(
                    get: { model.searchText },
                    set: { model.setSearch($0) }))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onAppear {
                        // Deferred a tick so the field is in the hierarchy
                        // before it takes key focus (as the composer does).
                        DispatchQueue.main.async { searchFocused = true }
                    }
                if !model.searchText.isEmpty {
                    Button {
                        model.setSearch("")
                        DispatchQueue.main.async { searchFocused = true }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))))
            Divider()
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
            // Spacing is priced per-gap, not uniformly: a flat HStack(spacing:10)
            // charges 50pt of mandatory air and pushes the default state to
            // 322pt — 6pt over the 316pt the panel offers (measured via
            // NSHostingView.fittingSize). This shape prices it at 306pt.
            HStack(spacing: 0) {
                HStack(spacing: 10) { quickFields }
                Spacer(minLength: 16)
                HStack(spacing: 8) { composerActions }
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
        // ViewThatFits caches its choice and doesn't re-evaluate when a chip
        // label changes width (verified with an offscreen sizeThatFits
        // harness: the unkeyed footer never re-measures in either direction).
        // Recreating it whenever a label changes forces a fresh choice, so
        // the footer re-merges after a long selection is undone.
        .id("\(draft.priority ?? "")|\(draft.category ?? "")|\(dueLabel)")
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
        // Always scroll inside the fixed region set in `body`. The MenuBarExtra
        // window doesn't reliably resize to changing content, so a self-sizing
        // list gets clipped by a too-small window and its lower rows vanish. A
        // fixed panel height with the list scrolling inside keeps every row
        // reachable — visible for short lists, scrollable for long ones.
        return Group {
            if groups.isEmpty {
                emptyState
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

    /// The empty-list copy. A search with no matches is the case that matters
    /// (#32): in a focused view it offers a one-tap widen to All open — the
    /// query carries over, so this is the discoverable route to find-anywhere
    /// and the answer to "did I delete that task?". At All open there's nowhere
    /// wider, so it just says nothing matched. With no search active it's the
    /// plain per-view empty copy.
    @ViewBuilder
    private var emptyState: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            Text(model.isCustom
                 ? "No tasks match this filter."
                 : "Nothing in \(model.activeTitle) right now.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if model.preset == .allOpen && !model.isCustom {
            Text("No open tasks match “\(query)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            VStack(spacing: 8) {
                Text("No matches in \(model.activeTitle).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Search all open tasks") { model.selectPreset(.allOpen) }
                    .buttonStyle(.link)
            }
            .multilineTextAlignment(.center)
        }
    }

    /// Whether an active title search is filtering the list (#32). A query
    /// forces every group open (below): while hunting for a task, a match must
    /// never hide behind a collapsed header. An open-but-empty search field
    /// isn't filtering, so folded groups (#19) behave normally until you type.
    private var isFilteringBySearch: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The rows themselves, shared by the scrolling and non-scrolling branches.
    /// A collapsed group (#19) keeps its header and folds its rows away; flat
    /// presets have no headers, so nothing there can collapse. An active search
    /// (#32) overrides the fold: matches always show, so you never click to
    /// reveal one. The stored fold state is untouched — it re-applies once the
    /// query clears.
    @ViewBuilder
    private func listContent(_ groups: [TaskGroup], grouped: Bool) -> some View {
        // The flattened visible ids drive the exit animation (#36): when a
        // completed row leaves `groups()`, this array changes and the wrapping
        // `.animation` turns the removal into a 0.2s fade + collapse rather than
        // a hard cut. Reduce Motion drops the animation to an instant cut.
        let visibleIDs = groups.flatMap { $0.tasks.map(\.id) }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.priority) { group in
                if grouped {
                    sectionHeader(group)
                }
                if !grouped || isFilteringBySearch || !model.isCollapsed(group.priority) {
                    ForEach(group.tasks) { task in
                        row(for: task, showPriority: !grouped)
                            .padding(.vertical, 6)
                            .transition(reduceMotion ? .identity : .opacity)
                        Divider()
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: visibleIDs)
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
    /// in a 340px panel. The leading chevron carries the affordance; the
    /// count sits inline after the name in both states (#26), so nothing
    /// moves on toggle except the chevron and the rows. No animation: the
    /// panel should feel instant.
    private func sectionHeader(_ group: TaskGroup) -> some View {
        // An active search forces the group open (#32), so show the expanded
        // chevron regardless of the stored fold state.
        let collapsed = model.isCollapsed(group.priority) && !isFilteringBySearch
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
                Text("(\(group.tasks.count))")
                    .foregroundStyle(.secondary)
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
            trailingControls(for: task)
        }
        .contentShape(Rectangle())
        // Hover reveals the trailing controls (#35). Only clear on leave if this
        // row is still the tracked one, so a stale leave from another row can't
        // wipe the current hover.
        .onHover { hovering in
            if hovering { hoveredRowID = task.id }
            else if hoveredRowID == task.id { hoveredRowID = nil }
        }
        // A brief highlight when a row bounces back after a failed completion
        // (#36), so the eye catches which task returned.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
                .opacity(model.restoredCompletions.contains(task.id) ? 0.18 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4),
                           value: model.restoredCompletions.contains(task.id)))
    }

    /// The row's trailing controls (#35): a Claude-Code launch icon and the
    /// actions menu, bare at rest and revealed together on hover. Revealed via
    /// opacity, not conditional removal, so the actions menu keeps its layout
    /// slot - the reschedule popover anchors to it, and the row height mustn't
    /// jump on hover. Kept visible while this row's date popover is open, or the
    /// pointer moving onto the popover would flicker the trigger out. A
    /// provisional quick-capture row (#37) shows nothing: it has no real page to
    /// launch or act on yet.
    @ViewBuilder
    private func trailingControls(for task: NotionTask) -> some View {
        if !task.isProvisional {
            let revealed = hoveredRowID == task.id || datePickerTaskID == task.id
            HStack(spacing: 12) {
                workInClaudeButton(for: task)
                rowActionsMenu(for: task)
            }
            .opacity(revealed ? 1 : 0)
            .allowsHitTesting(revealed)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: revealed)
        }
    }

    /// The one-click Claude-Code launch (#35): opens iTerm2 in the workspace and
    /// runs `claude` seeded with this task, marking it In Progress as it starts.
    private func workInClaudeButton(for task: NotionTask) -> some View {
        Button {
            onWorkInClaudeCode(task)
        } label: {
            Image(systemName: "terminal")
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("Work on in Claude Code")
        .accessibilityLabel("Work on in Claude Code")
    }

    /// Line 1: the title. Left-click opens the task in Notion (#21), so fields
    /// the app doesn't edit are one click away; right-click renames it inline
    /// (#28). SwiftUI has no bare right-click gesture — `.contextMenu` owns
    /// secondary-click — so a small AppKit router (below) owns both buttons on
    /// the title directly, which is why the row has no context menu. A task
    /// with no URL (only from a pre-#21 cached snapshot) still renames; its
    /// left-click open is simply a no-op.
    @ViewBuilder
    private func title(for task: NotionTask) -> some View {
        if model.editingTaskID == task.id {
            titleEditor(for: task)
        } else {
            Text(task.title)
                .lineLimit(2)
                .overlay(TitleClickRouter(
                    onLeftClick: { openInNotion(task) },
                    onRightClick: { model.beginEditing(taskID: task.id, title: task.title) }))
                .help("Left-click to open in Notion · Right-click to rename")
        }
    }

    /// The inline rename field (#28). Auto-focused with the text selected, so
    /// typing replaces the title wholesale (Finder's rename feel). Enter or
    /// losing focus saves; Escape cancels (routed via the shell's Esc monitor,
    /// which fires before the field can see the key). The draft lives in the
    /// model so the shell can commit it even as the panel tears down.
    private func titleEditor(for task: NotionTask) -> some View {
        TextField("Task name", text: Binding(
            get: { model.editingDraft },
            set: { model.setEditingDraft($0) }))
            .textFieldStyle(.roundedBorder)
            .lineLimit(1)
            .focused($editingFocused)
            .onSubmit { model.commitEditing() }
            .onAppear {
                // The field must be in the hierarchy before it can take focus;
                // select-all needs the field editor installed, one hop later.
                DispatchQueue.main.async {
                    editingFocused = true
                    DispatchQueue.main.async {
                        (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
                    }
                }
            }
            .onChange(of: editingFocused) { _, focused in
                // Blur saves (Q3), but only if this row is still the one being
                // edited — switching rows re-homes editing and commits the old.
                if !focused && model.editingTaskID == task.id {
                    model.commitEditing()
                }
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

    /// One-click complete (#36): shows a green tick at once and holds it for a
    /// beat before the row collapses out, via `AppModel.complete`. The tick is
    /// driven by `pendingCompletion` membership (a task mid-dwell) as well as a
    /// really-Done status. The glyph swaps with a symbol-replace transition and
    /// a one-off bounce; both are skipped under Reduce Motion. Inert on a
    /// provisional row (#37).
    private func completeButton(for task: NotionTask) -> some View {
        let ticked = model.pendingCompletion.contains(task.id) || task.status == "Done"
        return Button {
            Task { await model.complete(taskID: task.id) }
        } label: {
            Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ticked ? Color.green : Color.primary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .symbolEffect(.bounce, value: reduceMotion ? false : ticked)
        }
        .buttonStyle(.plain)
        .disabled(task.isProvisional)
        .help(ticked ? "Completing…" : "Mark done")
        .accessibilityLabel(ticked ? "Completing" : "Mark done")
    }

    /// Line 2: Priority · Due date · Category, with absent fields omitted so
    /// there are no stray separators. Renders nothing when all are absent.
    /// `showPriority` is false in grouped views, where the header carries it.
    ///
    /// The due date is its own `Text` so it alone carries the urgency tint
    /// (#25, ADR-0003); the separators and category stay secondary grey.
    @ViewBuilder
    private func metadata(for task: NotionTask, showPriority: Bool) -> some View {
        let due = task.relativeDueText()
        let withPriority = showPriority && task.priority != nil
        if withPriority || due != nil || task.category != nil {
            HStack(spacing: 5) {
                if withPriority, let priority = task.priority {
                    Circle()
                        .fill(colour(for: priority))
                        .frame(width: 7, height: 7)
                    Text(priority)
                    if due != nil || task.category != nil { Text("·") }
                }
                if let due {
                    dueText(due, bucket: task.dueBucket())
                    if task.category != nil { Text("·") }
                }
                if let category = task.category {
                    Text(category)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The due segment, tinted by urgency (#25): overdue pops red semibold,
    /// today is orange, the coming week is amber, everything else keeps the
    /// metadata line's secondary grey. The tint is confined to this text —
    /// the dot stays the priority channel (ADR-0003). Colours live in
    /// `DueColor`, shared with the quick-capture capsule (#34).
    @ViewBuilder
    private func dueText(_ text: String, bucket: DueBucket) -> some View {
        if let tint = DueColor.tint(for: bucket) {
            Text(text)
                .fontWeight(bucket == .overdue ? .semibold : .regular)
                .foregroundStyle(tint)
        } else {
            Text(text)
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

    /// The row's right-side control (#33): an actions menu behind an ellipsis
    /// icon. Status, Priority and Reschedule are all submenus, each checkmarking
    /// its current value, so the three read consistently. Right-click stays
    /// bound to inline rename (#28) - this is an explicit menu, not a
    /// secondary-click context menu, so the two don't collide. The status used
    /// to sit here as the label; it moved into the Status submenu, so status is
    /// no longer shown on the row itself.
    private func rowActionsMenu(for task: NotionTask) -> some View {
        Menu {
            statusSubmenu(for: task)
            priorityMenu(for: task)
            rescheduleMenu(for: task)
            // "Work on in Claude Code" (#35): the discoverable, stable home for
            // the launch that also lives behind the hover terminal icon.
            Divider()
            Button {
                onWorkInClaudeCode(task)
            } label: {
                Label("Work on in Claude Code", systemImage: "terminal")
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // The calendar popover anchors to this row's control and presents only
        // when this row's "Pick a date…" was chosen.
        .popover(isPresented: Binding(
            get: { datePickerTaskID == task.id },
            set: { if !$0 { datePickerTaskID = nil } })) {
            dateEditor(for: task)
        }
    }

    /// The Status submenu (#33): the selectable statuses, checkmarked on the
    /// current one. Was a flat list under the old label; now a submenu so it's
    /// consistent with Priority and Reschedule.
    private func statusSubmenu(for task: NotionTask) -> some View {
        Menu("Status") {
            ForEach(NotionConfig.selectableStatuses, id: \.self) { state in
                Button {
                    // Done routes through the same tick-and-collapse path as the
                    // checkbox (#36), so both entry points behave identically;
                    // the other statuses take the plain write.
                    if state == "Done" {
                        Task { await model.complete(taskID: task.id) }
                    } else {
                        Task { await model.setStatus(taskID: task.id, to: state) }
                    }
                } label: {
                    checkmarked(state, when: task.status == state)
                }
            }
        }
    }

    /// The Priority submenu (#33): one item per schema priority, checkmarked on
    /// the current value, plus a "No priority" item that clears it (also
    /// checkmarked when unset). Options come live from the schema, like the
    /// composer's priority field, so options the app has never heard of appear.
    private func priorityMenu(for task: NotionTask) -> some View {
        Menu("Priority") {
            ForEach(model.schemaOptions.priorities, id: \.self) { priority in
                Button {
                    Task { await model.setPriority(taskID: task.id, to: priority) }
                } label: {
                    checkmarked(priority, when: task.priority == priority)
                }
            }
            Divider()
            Button {
                Task { await model.setPriority(taskID: task.id, to: nil) }
            } label: {
                checkmarked("No priority", when: task.priority == nil)
            }
        }
    }

    /// The Reschedule submenu (#33): the current due date as a disabled context
    /// line, the quick relative options, "Pick a date…" (opens the calendar
    /// popover), and Clear. The relative maths lives in `ReschedulePreset`.
    private func rescheduleMenu(for task: NotionTask) -> some View {
        Menu("Reschedule") {
            if let due = task.dueDate {
                Text("Due \(due.formatted(.dateTime.day().month(.abbreviated).year()))")
                Divider()
            }
            ForEach(ReschedulePreset.allCases, id: \.self) { preset in
                Button(preset.label) {
                    Task { await model.setDueDate(taskID: task.id, to: preset.date()) }
                }
            }
            Button("Pick a date…") {
                // Defer past the menu's own dismissal so the popover presents
                // cleanly rather than racing the closing menu.
                let seed = task.dueDate ?? Calendar.current.startOfDay(for: Date())
                DispatchQueue.main.async {
                    draftDueDate = seed
                    datePickerTaskID = task.id
                }
            }
            Divider()
            Button("Clear due date") {
                Task { await model.setDueDate(taskID: task.id, to: nil) }
            }
        }
    }

    /// A menu-item label that shows a leading checkmark when `on`, matching the
    /// settings menu's selected-row style (#33).
    @ViewBuilder
    private func checkmarked(_ title: String, when on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// The "Pick a date…" popover (#33): a graphical month calendar seeded to
    /// the task's current due date. Commit-on-tap - selecting a day writes it
    /// and dismisses; month-navigation doesn't change the selection, so it's
    /// safe. Re-picking the same day is a harmless no-op (the model guards it).
    private func dateEditor(for task: NotionTask) -> some View {
        DatePicker("Due date", selection: $draftDueDate, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding()
            .frame(minWidth: 260)
            .onChange(of: draftDueDate) { _, newDate in
                Task { await model.setDueDate(taskID: task.id, to: newDate) }
                datePickerTaskID = nil
            }
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

    /// In the header since the footer's deletion (#20). The last-fetched clock
    /// (#7) lives here as a passive first line — the stale badge still carries
    /// the warning role. Quit appears both here and in the menu bar icon's
    /// right-click menu (#24): right-click is invisible to anyone who hasn't
    /// tried it, so the gear menu carries the discoverable copy.
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
            // The global quick-capture shortcut (#34): its current combination,
            // a way to record a new one, and a reset to the ⌥Space default.
            Menu("Quick-capture shortcut") {
                Text("Current: \(model.hotKey.displayString)")
                Button("Record new shortcut…") { onRecordShortcut() }
                if model.hotKey != .default {
                    Button("Reset to ⌥Space") { model.setHotKey(.default) }
                }
            }
            // The global show-panel shortcut (#39): symmetric with quick-capture
            // above — current combination, record a new one, reset to the default.
            Menu("Show panel shortcut") {
                Text("Current: \(model.panelHotKey.displayString)")
                Button("Record new shortcut…") { onRecordPanelShortcut() }
                if model.panelHotKey != .defaultPanel {
                    Button("Reset to \(HotKey.defaultPanel.displayString)") {
                        model.setPanelHotKey(.defaultPanel)
                    }
                }
            }
            // The Claude Code workspace directory (#35): its current path and a
            // native folder chooser to change it.
            Menu("Claude workspace") {
                Text(model.claudeWorkspaceDirectory)
                Button("Choose folder…") { onChooseWorkspace() }
            }
            Divider()
            // Same label and shortcut as the right-click item — two items
            // doing the same thing must read the same.
            Button("Quit Notion Tasks") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
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

/// Routes clicks on a task title without a context menu (#28): left-click opens
/// the task in Notion, right-click begins an inline rename. SwiftUI has no bare
/// right-click gesture (`.contextMenu` owns secondary-click), so this small
/// AppKit view owns both mouse buttons directly. It draws nothing and sits as
/// an overlay over the SwiftUI `Text`, which renders underneath.
private struct TitleClickRouter: NSViewRepresentable {
    var onLeftClick: () -> Void
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> RouterView {
        let view = RouterView()
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: RouterView, context: Context) {
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
    }

    final class RouterView: NSView {
        var onLeftClick: (() -> Void)?
        var onRightClick: (() -> Void)?

        // Claim the mouse sequence so mouseUp is delivered here.
        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            // Only a click that ends inside counts (a drag that leaves cancels).
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) { onLeftClick?() }
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
        }

        // Be the hit target for clicks over the title's frame.
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
    }
}
