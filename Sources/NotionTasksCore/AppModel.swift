import Foundation
import Combine

/// What the panel is currently showing.
public enum TaskListState: Equatable {
    case needsToken
    case loading
    case loaded([NotionTask])
    case failed(String)
}

/// Drives the panel: reads the stored token, fetches tasks, and maps outcomes
/// to `TaskListState`. This is where "prompt on first run, reuse a stored
/// token, clear a rejected token" lives — the SwiftUI views just render `state`.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var state: TaskListState = .needsToken

    private let tokenStore: TokenStore
    private let makeClient: (String) -> NotionClient

    /// - Parameter makeClient: builds a client for a token. Injected so tests
    ///   can supply a stubbed transport; the app supplies `URLSession`.
    public init(tokenStore: TokenStore, makeClient: @escaping (String) -> NotionClient) {
        self.tokenStore = tokenStore
        self.makeClient = makeClient
    }

    /// Call on launch. Loads tasks if a token is stored, else prompts for one.
    public func start() async {
        guard let token = tokenStore.read(), !token.isEmpty else {
            state = .needsToken
            return
        }
        await load(token: token)
    }

    /// Call when the user submits a token from the entry field.
    public func submit(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .needsToken
            return
        }
        try? tokenStore.save(trimmed)
        await load(token: trimmed)
    }

    /// Re-fetch with the token already stored.
    public func refresh() async {
        await start()
    }

    /// Forget the stored token and return to the entry field.
    public func signOut() {
        try? tokenStore.delete()
        state = .needsToken
    }

    private func load(token: String) async {
        state = .loading
        do {
            let tasks = try await makeClient(token).fetchTasks()
            state = .loaded(tasks)
        } catch NotionClientError.unauthorized {
            // The token is bad; drop it so the next launch re-prompts.
            try? tokenStore.delete()
            state = .failed("That token was rejected. Check it and enter it again.")
        } catch let NotionClientError.httpError(code) {
            state = .failed("Notion returned an error (HTTP \(code)). Try again shortly.")
        } catch {
            state = .failed("Couldn't reach Notion. Check your connection and try again.")
        }
    }
}
