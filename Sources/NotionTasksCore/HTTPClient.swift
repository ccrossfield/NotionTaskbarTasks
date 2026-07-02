import Foundation

/// The HTTP transport seam. `NotionClient` depends on this, not on `URLSession`
/// directly, so tests can inject a stub and assert on the request without
/// hitting the network.
///
/// The signature deliberately mirrors `URLSession.data(for:)`, so the real
/// implementation is a zero-cost conformance.
public protocol HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {}
