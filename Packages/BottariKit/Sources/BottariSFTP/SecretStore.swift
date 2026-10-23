import Foundation
import KeychainAccess

/// Somewhere to keep passwords and key passphrases out of the saved-sites file.
public protocol SecretStore: Sendable {
    func secret(for key: String) throws -> String?
    /// Stores `value`, or removes the secret when `value` is nil.
    func setSecret(_ value: String?, for key: String) throws
}

/// The macOS Keychain. With `synchronizable`, secrets also go to iCloud Keychain,
/// which needs a signed app.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let synchronizable: Bool

    public init(service: String, synchronizable: Bool = false) {
        self.service = service
        self.synchronizable = synchronizable
    }

    // `Keychain` is a non-Sendable class; a fresh one per call is cheap.
    private var keychain: Keychain {
        Keychain(service: service).synchronizable(synchronizable)
    }

    public func secret(for key: String) throws -> String? {
        try keychain.get(key)
    }

    public func setSecret(_ value: String?, for key: String) throws {
        if let value {
            try keychain.set(value, key: key)
        } else {
            try keychain.remove(key)
        }
    }
}

/// Secrets kept in memory only, for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    public init(_ secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    public func secret(for key: String) throws -> String? {
        lock.withLock { secrets[key] }
    }

    public func setSecret(_ value: String?, for key: String) throws {
        lock.withLock { secrets[key] = value }
    }
}
