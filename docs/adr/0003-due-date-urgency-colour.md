# 3. Due-date urgency colour

Date: 2026-07-03

## Status

Accepted. Amends ADR-0002 decision 3 ("colour is rationed to priority").
Spec agreed with the user in a grilling session; built as issue #25.

## Context

ADR-0002 rationed colour to the priority dot so the two-line rows stay quiet.
That left due dates undifferentiated: an overdue task and one due next month
read identically on the metadata line. With 9 overdue tasks in the cache
snapshot at the time of writing, overdue needed to pop without repainting the
rows.

## Decision

1. **Colour now also encodes due-date urgency, confined to the due-date text
   segment** on the metadata line. The priority dot is unchanged; category and
   separators stay secondary grey. Dot = priority, text tint = urgency: two
   spatially distinct channels, so red-on-red (P0 + overdue) reads as
   agreement, not conflict.
2. **Discrete buckets over a week horizon, not a continuous gradient**:
   overdue (red, semibold), today (orange), soon = +1 to +7 days (amber),
   later / undated (secondary grey, unchanged). The orange and amber are both
   custom adaptive colours: system yellow is illegible at caption size on a
   light background, and live testing showed system orange is too. Only the
   red is a standard system colour.
3. **Wording gains a relative middle ground**: "Tomorrow" at +1, weekday name
   ("Wed") at +2 to +6, short date from +7. Weekday names stop at +6 because a
   task exactly +7 out shares today's weekday name and would read as due
   today.
4. **Done tasks carry no urgency**: bucket `none` and a plain short date,
   regardless of due date. A red "Overdue" on a finished task is an alarm
   about nothing.

## Consequences

- Per the ADR-0002 semantics/presentation split, the bucket boundaries and
  wording live in `NotionTasksCore` (`DueBucket`, `relativeDueText()`),
  parameterised by `now`/`calendar` and covered by checks; the view only maps
  bucket → colour/weight.
- The metadata line renders due date and category as separate `Text` segments
  (previously one joined string) so the tint stays on the due segment.
- Rejected: continuous hue gradient (indistinguishable at caption size,
  untestable), coloured pill/second dot/row wash (louder than the quiet
  two-line design), day-count wording like "2d" (cryptic).
