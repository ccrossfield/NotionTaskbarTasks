import Foundation

/// A tiny dependency-free check harness. Not a real test framework — it exists
/// only because this machine has Command Line Tools without XCTest or the Swift
/// Testing macro plugin, so `swift test` can't run. Each `test` body reads like
/// a spec and ports 1:1 to XCTest/Swift Testing if Xcode is installed later.
final class CheckRun {
    private var failures: [String] = []
    private var passed = 0
    private var current = ""

    func suite(_ name: String) { print("\n\(name)") }

    func test(_ name: String, _ body: () async throws -> Void) async {
        current = name
        do {
            try await body()
            passed += 1
            print("  ✓ \(name)")
        } catch {
            failures.append("\(name): threw \(error)")
            print("  ✗ \(name): threw \(error)")
        }
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                file: StaticString = #filePath, line: UInt = #line) {
        guard !condition else { return }
        failures.append("\(current): \(message()) (\(file):\(line))")
        print("  ✗ \(current): \(message())")
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                                   file: StaticString = #filePath, line: UInt = #line) {
        expect(actual == expected, "expected \(expected), got \(actual)", file: file, line: line)
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failures.count) failed")
        if !failures.isEmpty {
            print("\nFailures:")
            failures.forEach { print("  - \($0)") }
            exit(1)
        }
        exit(0)
    }
}

struct CheckError: Error, CustomStringConvertible { let description: String }

/// Unwrap-or-throw, so a nil in a check body fails that check cleanly.
func require<T>(_ value: T?, _ message: String = "unexpected nil") throws -> T {
    guard let value else { throw CheckError(description: message) }
    return value
}
