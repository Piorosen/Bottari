import BottariCore
import Foundation
import KeychainAccess

/// Somewhere to keep passwords and key passphrases out of the saved-sites file.
public protocol SecretStore: Sendable {
    func secret(for key: String) throws -> String?
    /// Stores `value`, or removes the secret when `value` is nil.
    func setSecret(_ value: String?, for key: String) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// A secret is stored under `key` but this app may not read it, e.g. it was
    /// saved by a build with a different signature, or the app's binary changed
    /// while it ran. Asking for the secret again and saving it fixes that.
    case unreadable(key: String)
}

extension SecretStore {
    /// The secret, or nil when none is stored or this app may not read it.
    public func readableSecret(for key: String) throws -> String? {
        do {
            return try secret(for: key)
        } catch SecretStoreError.unreadable {
            return nil
        }
    }
}

/// Passwords and passphrases the user typed for a connection, by their key in
/// the secret store, each with the user's choice whether to keep it there.
public struct TypedSecrets: Equatable, Sendable {
    private var values: [String: String] = [:]
    private var kept: Set<String> = []

    public init() {}

    public subscript(key: String) -> String? { values[key] }

    public mutating func set(_ value: String, for key: String, keeping: Bool) {
        values[key] = value
        if keeping { kept.insert(key) } else { kept.remove(key) }
    }

    /// `stored`, with these in front of it.
    public func over(_ stored: any SecretStore) -> any SecretStore {
        Overlay(typed: values, stored: stored)
    }

    /// Saves the ones the user chose to keep, once the connection works.
    public func keep(in store: any SecretStore) {
        for key in kept {
            do {
                try store.setSecret(values[key], for: key)
            } catch {
                Log.app.error("키체인에 저장하지 못함: \(key): \(error.localizedDescription)")
            }
        }
    }

    private struct Overlay: SecretStore {
        let typed: [String: String]
        let stored: any SecretStore

        func secret(for key: String) throws -> String? {
            try typed[key] ?? stored.secret(for: key)
        }

        func setSecret(_ value: String?, for key: String) throws {
            try stored.setSecret(value, for: key)
        }
    }
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

    /// Keychain answers meaning the item is there but not for this app.
    private static let refusals: Set<Status> = [.authFailed, .interactionNotAllowed, .userCanceled, .invalidOwnerEdit]

    public func secret(for key: String) throws -> String? {
        do {
            return try keychain.get(key)
        } catch let status as Status where Self.refusals.contains(status) {
            Log.app.error("키체인 항목을 읽을 수 없음 (\(status.rawValue)): \(key)")
            throw SecretStoreError.unreadable(key: key)
        }
    }

    /// An item this app may not update is removed and written again, so it
    /// belongs to the app as it is now.
    public func setSecret(_ value: String?, for key: String) throws {
        guard let value else {
            try keychain.remove(key)
            return
        }
        do {
            try keychain.set(value, key: key)
        } catch {
            Log.app.error("키체인 항목을 바꿀 수 없어 다시 만듦: \(key): \(error.localizedDescription)")
            try keychain.remove(key)
            try keychain.set(value, key: key)
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
