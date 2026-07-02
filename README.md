# Notion Tasks (macOS menu bar)

A native SwiftUI menu bar app that shows tasks from a Notion database and (in
later slices) lets you filter, sort and change their status. See the PRD in
GitHub issue #1 and the API decisions in `docs/adr/0001-notion-api-access.md`.

## Layout

- `Sources/NotionTasksCore` - all testable logic: the task model + decoder, the
  `URLSession`-backed `NotionClient` (behind an `HTTPClient` seam), the
  `KeychainTokenStore` (behind a `TokenStore` seam), and the `AppModel` that
  wires them together.
- `Sources/NotionTasksApp` - the SwiftUI `MenuBarExtra` shell. Thin; renders
  `AppModel.state`.
- `Tests/NotionTasksChecks` - the check suite (see below).

## Build and run

```sh
swift build                 # compile everything
./scripts/make-app.sh       # assemble a launchable NotionTasks.app
open NotionTasks.app        # a checklist icon appears in the menu bar (no Dock icon)
```

On first run the panel asks for a Notion internal integration token; it's saved
to the Keychain and reused after that. Create the token at
<https://www.notion.so/my-integrations>, then share the Tasks database with it
(database `...` menu -> Connections).

## Tests

This repo's machine has only the Command Line Tools, which ship neither XCTest
nor the Swift Testing macro plugin - so `swift test` cannot run. The checks are
therefore a small dependency-free executable:

```sh
swift run NotionTasksChecks
```

Each check reads like a spec and ports 1:1 to XCTest / Swift Testing if a full
Xcode is installed later. The two test seams are the `HTTPClient` transport
(stubbed) and the `TokenStore` (in-memory fake).

## Test fixtures

`Tests/NotionTasksChecks/Fixtures/query_response.json` is the decode fixture.
See its README for provenance and how to re-capture it from the live database.
