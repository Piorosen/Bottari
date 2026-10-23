import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// Which server host keys to accept.
public enum HostKeyTrust: Sendable {
    /// Accepts any key. Only for tests against a server on this machine.
    case acceptAnything
    /// Trusts a server's key the first time and refuses it if it changes later, like `ssh`.
    case knownHosts(KnownHosts)

    func validator(for endpoint: SFTPEndpoint) -> SSHHostKeyValidator {
        switch self {
        case .acceptAnything:
            .acceptAnything()
        case .knownHosts(let store):
            .custom(KnownHostsValidator(store: store, endpoint: endpoint))
        }
    }

    /// The host key mismatch recorded during the last connection attempt, if any.
    /// NIO wraps validator failures, so the connection error alone does not say why.
    func rejection(for endpoint: SFTPEndpoint) -> SFTPConnectError? {
        guard case .knownHosts(let store) = self else { return nil }
        return store.takeRejection(for: endpoint)
    }
}

/// Remembered host keys, one per `host:port`, optionally saved to a JSON file.
public final class KnownHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]
    private var rejections: [String: SFTPConnectError] = [:]
    private let fileURL: URL?

    /// Loads remembered keys from `fileURL` if it exists; `nil` keeps them in memory only.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            keys = saved
        } else {
            keys = [:]
        }
    }

    /// The remembered key in OpenSSH form (`ssh-ed25519 AAAA…`), if any.
    public func trustedKey(for endpoint: SFTPEndpoint) -> String? {
        lock.withLock { keys[endpoint.hostKeyID] }
    }

    /// Forgets a server's key, e.g. after the user confirms it was reinstalled.
    public func forget(_ endpoint: SFTPEndpoint) {
        lock.withLock {
            keys[endpoint.hostKeyID] = nil
            save()
        }
    }

    /// Checks a presented key: remembers it if the host is new, rejects it if it differs.
    func check(_ presented: String, for endpoint: SFTPEndpoint) -> Bool {
        lock.withLock {
            let id = endpoint.hostKeyID
            guard let trusted = keys[id] else {
                keys[id] = presented
                save()
                return true
            }
            guard trusted == presented else {
                rejections[id] = .hostKeyChanged(
                    host: id,
                    expected: Self.fingerprint(ofOpenSSHKey: trusted),
                    presented: Self.fingerprint(ofOpenSSHKey: presented)
                )
                return false
            }
            return true
        }
    }

    func takeRejection(for endpoint: SFTPEndpoint) -> SFTPConnectError? {
        lock.withLock { rejections.removeValue(forKey: endpoint.hostKeyID) }
    }

    /// `SHA256:…` fingerprint as `ssh-keygen -l` prints it.
    public static func fingerprint(ofOpenSSHKey key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return key }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Must be called with `lock` held.
    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(keys) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Fails the SSH handshake; the reason is kept in `KnownHosts` for the caller to report.
struct HostKeyRejected: Error {}

struct KnownHostsValidator: NIOSSHClientServerAuthenticationDelegate {
    let store: KnownHosts
    let endpoint: SFTPEndpoint

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if store.check(String(openSSHPublicKey: hostKey), for: endpoint) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(HostKeyRejected())
        }
    }
}
