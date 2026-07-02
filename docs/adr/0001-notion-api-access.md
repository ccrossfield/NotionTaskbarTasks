# 1. Notion API access for the Tasks menu bar app

Date: 2026-07-02

## Status

Accepted. Confirmed end-to-end by a throwaway spike (`spike/`) against the live database on 2026-07-02.

## Context

The app reads and writes the "🎯 Tasks" Notion database via the raw REST API (`URLSession`), storing an auth token in the macOS Keychain. A spike exercised the real API to settle how, before any Swift is written. Facts it confirmed:

- The database (`f4a11f22-9f37-4ff0-b2b1-660561d3e5fa`) is **multi-source**: it holds two data sources - the real "🎯 Tasks" (`e19b11fa-a660-4de2-8482-b840210db08f`) and a stray empty one (`30b8d592-…`). Querying the *database* is ambiguous.
- `Status` is a grouped `status` property. Groups: `To-do` = {To Do, Blocked}, `In progress` = {In Progress}, `Complete` = {Done}.
- The Notion REST status filter matches option **names**, not groups.

## Decision

1. **Target the data source, never the database.** All queries hit `POST /v1/data_sources/e19b11fa…/query`.
2. **Pin `Notion-Version: 2025-09-03`** (the data-sources API).
3. **Derive the "open" status set from the live schema at runtime** - the options not in the `Complete` group - and build the status filter as an `OR` over those names. Do **not** hardcode `does_not_equal "Done"`. ("Open" therefore includes **Blocked**.)
4. **Status write-back** uses `PATCH /v1/pages/{id}` with `{"properties":{"Status":{"status":{"name":"<state>"}}}}`. A live round-trip (`To Do → Blocked → To Do`) confirmed Notion accepts this shape.
5. **Auth via a scoped internal connection** shared with only the Tasks DB (least privilege), not a personal access token. Token in Keychain.
6. **Poll for updates**; respect the ~3 req/s average limit and honour `Retry-After` on `429`.

## Consequences

- Renaming or adding statuses in Notion is handled automatically by the schema-derived filter - **provided** any new "done-like" status is placed in the `Complete` group, otherwise it is treated as open.
- The multi-source assumption lives in one place (the data-source id constant). If the stray empty source is removed, or a real second source is added, that constant must be revisited.
- A poll-based sync means changes made in Notion appear only on the next poll; there is no push. Acceptable for a personal tool.

## Verified

Spike on 2026-07-02 passed all of: auth, data-source schema retrieve, filtered query ("late or due today"), field decode (Status/Priority/Due/Category), sort, paging, and a live status round-trip. See `spike/NOTES.md`.
