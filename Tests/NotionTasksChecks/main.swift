import Foundation

let checks = CheckRun()

await decodingChecks(checks)
await schemaChecks(checks)
await taskPresentationChecks(checks)
await taskListEngineChecks(checks)
await reschedulePresetChecks(checks)
await composerChecks(checks)
await priorityShortcutChecks(checks)
await hotKeyChecks(checks)
await clientChecks(checks)
await taskCacheChecks(checks)
await preferencesChecks(checks)
await appModelChecks(checks)

checks.finish()
