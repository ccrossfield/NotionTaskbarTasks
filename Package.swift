// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NotionTasks",
    platforms: [.macOS(.v14)],
    targets: [
        // All testable logic: models + decode, the URLSession-backed Notion
        // client (behind an HTTPClient seam), the Keychain token store (behind
        // a TokenStore seam), and the AppModel that wires them together.
        .target(name: "NotionTasksCore"),

        // The SwiftUI MenuBarExtra shell. Thin; not unit-tested (verified by
        // running the app). Depends on the core for all behaviour.
        .executableTarget(
            name: "NotionTasksApp",
            dependencies: ["NotionTasksCore"]
        ),

        // Headless checks. Run with `swift run NotionTasksChecks`.
        //
        // This is a dependency-free executable rather than a `.testTarget`
        // because this machine has only the Command Line Tools, which ship
        // neither XCTest nor the Swift Testing macro plugin — so `swift test`
        // cannot run. The check bodies read like specs and port 1:1 to XCTest
        // or Swift Testing if a full Xcode is installed later.
        //
        // Fixtures are Notion query-response JSON (see Fixtures/README.md).
        .executableTarget(
            name: "NotionTasksChecks",
            dependencies: ["NotionTasksCore"],
            path: "Tests/NotionTasksChecks",
            resources: [.copy("Fixtures")]
        ),
    ]
)
