# 2. Task list presentation and default view

Date: 2026-07-02

## Status

Accepted. Settled with the user from the mockup before building the filtered
views (#4-#6).

## Context

Issues #4-#6 (filtering, preset switching, custom filter) all render task rows.
The row design and the default view were unspecified, and #2/#3 shipped a
placeholder flat "title … status" list. Building the filtered views without
settling presentation would mean building the rows twice. Six design questions
were put to the user; their answers are recorded here as the single source the
slices follow.

## Decision

1. **Two-line rows.** Line 1: task title. Line 2: a metadata line showing
   **Priority · Due date · Category**.
2. **Relative due dates.** Render as "Overdue" / "Today" / otherwise a short
   date ("2 Jul").
3. **Colour is rationed to priority.** A small dot only: **P0 red / P1 amber /
   P2 green** (matches the spike's P2=green finding). Everything else is
   monochrome — no status colour, no category colour.
4. **One-click complete.** Each row has a checkbox/circle that sets status to
   Done in one click. The full status menu from #3 stays for the other
   transitions (Blocked / To Do / In Progress).
5. **Grouped by priority with section headers.** Priority-sorted views group
   rows under **P0 / P1 / P2** headers rather than a flat list with badges.
6. **Default view on launch is Pivotal Priorities** — open Work-category tasks,
   Start from ≤ today or empty, grouped by priority, sorted by priority then Due
   date. This supersedes the earlier assumption (issue #4) that the default was
   "Late or due today"; that view becomes one of the switchable presets (#5).

## Consequences

- **The task model must grow.** `NotionTask` currently carries only title +
  status; it needs **Priority, Due date, Category and Start from** decoded from
  the query response. This decode is a prerequisite for both the new rows and
  the filters, so it lands first.
- **Issues #4/#5 are re-scoped.** #4 shifts from "default = Late or due today"
  to delivering the **Pivotal Priorities** default view; "Late or due today"
  moves into the #5 preset set. The open-status set is still schema-derived per
  ADR-0001 (not hardcoded).
- **Presentation vs semantics split.** Grouping, relative-date formatting and
  the priority colour live in the SwiftUI view layer. The filter/sort/group
  *semantics* (which tasks, in what order, under which group) live in a testable
  engine in `NotionTasksCore`, exercised through the existing seams.
- One-click complete is a thin reuse of `AppModel.setStatus(_, to: "Done")`.
