import Foundation
import Security

/// The token-store seam. The app persists the Notion integration token in the
/// Keychain; tests use an in-memory fake.
public protocol TokenStore {
    /// The stored token, or `nil` if none is stored.
    func read() -> String?
    /// Store (or replace) the token.
    func save(_ token: String) throws
    /// Remove any stored token.
    func delete() throws
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Stores the token as a generic-password Keychain item. Not unit-tested
/// headlessly (it touches the system Keychain); verified by running the app.
public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    public init(service: String = "uk.co.pivotal.notiontasks",
                account: String = "notion-integration-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        SecItemDelete(baseQuery as CFDictionary) // replace any existing item
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
