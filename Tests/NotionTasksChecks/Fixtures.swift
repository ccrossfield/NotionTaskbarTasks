import Foundation

/// Loads a JSON fixture from `Tests/NotionTasksChecks/Fixtures/`.
func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw CheckError(description: "fixture \(name).json not found in bundle")
    }
    return try Data(contentsOf: url)
}
