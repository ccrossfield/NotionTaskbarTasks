import Foundation

let checks = CheckRun()

await decodingChecks(checks)
await schemaChecks(checks)
await taskPresentationChecks(checks)
await taskListEngineChecks(checks)
await clientChecks(checks)
await taskCacheChecks(checks)
await appModelChecks(checks)

checks.finish()
