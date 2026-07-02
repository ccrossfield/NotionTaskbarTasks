import Foundation

let checks = CheckRun()

await decodingChecks(checks)
await clientChecks(checks)
await appModelChecks(checks)

checks.finish()
