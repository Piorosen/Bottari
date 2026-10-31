import BottariCore
import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// Which server host keys to accept.
public enum HostKeyTrust: Sendable {
    /// Accepts any key. Only for tests against a server on this machine.
    case acceptAnything
    /// Trusts a server's key the first time and refuses it if it changes later,
    /// like `ssh`, taking `ssh`'s own known_hosts into account.
    case knownHosts(KnownHosts)

    func validator(for endpoint: SFTPEndpoint) -> SSHHostKeyValidator {
        switch self {
        case .acceptAnything:
            .acceptAnything()
        case .knownHosts(let store):
            .custom(KnownHostsValidator(store: store, endpoint: endpoint))
        }
    }

    /// The key this trust expects from `endpoint` as a known_hosts line, or nil
    /// when it accepts anything or has not seen the server.
    func knownHostsLine(for endpoint: SFTPEndpoint) -> String? {
        guard case .knownHosts(let store) = self, let key = store.trustedKey(for: endpoint) else { return nil }
        return "\(endpoint.hostKeyID) \(key)"
    }

    /// The host key mismatch recorded during the last connection attempt, if any.
    /// NIO wraps validator failures, so the connection error alone does not say why.
    func rejection(for endpoint: SFTPEndpoint) -> SFTPConnectError? {
        guard case .knownHosts(let store) = self else { return nil }
        return store.takeRejection(for: endpoint)
    }
}

/// Remembered host keys, one per `host:port`, optionally saved to a JSON file.
/// `ssh`'s known_hosts files are read too, never written: a key `ssh`
/// already trusts needs no second confirmation, and one that contradicts
/// them is refused as `ssh` would.
public final class KnownHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]
    private var rejections: [String: SFTPConnectError] = [:]
    private let fileURL: URL?
    private let openSSHFiles: [URL]

    /// `ssh`'s own lists: the user's and the system-wide one.
    public static let openSSHDefaultFiles = [
        URL(fileURLWithPath: UserHome.path).appending(path: ".ssh/known_hosts"),
        URL(fileURLWithPath: "/etc/ssh/ssh_known_hosts"),
    ]

    /// Loads remembered keys from `fileURL` if it exists; `nil` keeps them in
    /// memory only. `openSSHFiles` are consulted on every check.
    public init(fileURL: URL?, openSSHFiles: [URL] = []) {
        self.fileURL = fileURL
        self.openSSHFiles = openSSHFiles
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

    /// Every remembered key by `host` or `[host]:port`, sorted, for showing and forgetting them.
    public var remembered: [(host: String, key: String)] {
        lock.withLock { keys.sorted { $0.key < $1.key }.map { (host: $0.key, key: $0.value) } }
    }

    /// Forgets a server's key, e.g. after the user confirms it was reinstalled.
    public func forget(_ endpoint: SFTPEndpoint) {
        forget(hostKeyID: endpoint.hostKeyID)
    }

    /// Trusts `key` (`type base64`) for a `host` or `[host]:port` name, after
    /// the user checked a key `hostKeyNotListed` could not vouch for.
    public func trust(_ key: String, hostKeyID: String) {
        lock.withLock {
            keys[hostKeyID] = key
            save()
        }
    }

    /// Forgets the key for a `host` or `[host]:port` name, as `hostKeyChanged` reports it.
    public func forget(hostKeyID: String) {
        lock.withLock {
            keys[hostKeyID] = nil
            save()
        }
    }

    /// Checks a presented key: remembers it if the host is new, rejects it if
    /// it differs. A key in `ssh`'s known_hosts is trusted and remembered (it
    /// may be the new key of a reinstalled server); a host `ssh` knows with a
    /// different key of the same kind, or a revoked key, is refused.
    func check(_ presented: String, for endpoint: SFTPEndpoint) -> Bool {
        let openSSH = OpenSSHKnownHosts.load(openSSHFiles).verdict(for: presented, host: endpoint.hostKeyID)
        return lock.withLock {
            let id = endpoint.hostKeyID
            switch openSSH {
            case .trusted:
                if keys[id] != presented {
                    keys[id] = presented
                    save()
                }
                return true
            case .revoked:
                rejections[id] = .hostKeyRevoked(host: id)
                Log.connection.error("\(id): known_hosts에서 폐기된 호스트 키")
                return false
            case .changed(let expected) where keys[id] == nil:
                Log.connection.error("\(id): known_hosts와 다른 호스트 키")
                rejections[id] = .hostKeyChangedInKnownHosts(
                    host: id,
                    expected: Self.fingerprint(ofOpenSSHKey: expected),
                    presented: Self.fingerprint(ofOpenSSHKey: presented)
                )
                return false
            case .otherKinds(let known) where keys[id] == nil:
                // `ssh` would ask here; trusting it silently would let a
                // server in the middle pick a kind known_hosts says nothing of.
                Log.connection.error("\(id): known_hosts에 다른 종류의 호스트 키만 있음")
                rejections[id] = .hostKeyNotListed(host: id, known: known.map(Self.fingerprint(ofOpenSSHKey:)), presented: presented)
                return false
            case .changed, .otherKinds, .unknown:
                break
            }
            guard let trusted = keys[id] else {
                keys[id] = presented
                save()
                return true
            }
            guard trusted == presented else {
                Log.connection.error("\(id): 저장된 것과 다른 호스트 키")
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

/// `ssh`'s known_hosts: `[@marker] patterns keytype base64 [comment]` per
/// line, host names plain (with `*`, `?` and `!`) or hashed (`|1|salt|hash`).
struct OpenSSHKnownHosts {
    enum Verdict: Equatable {
        case trusted
        /// The host is listed with another key of the same kind.
        case changed(expected: String)
        /// The host is listed, but only with keys of other kinds.
        case otherKinds(known: [String])
        case revoked
        case unknown
    }

    private struct Entry {
        var marker: String?
        var hosts: String
        /// `type base64`, as `String(openSSHPublicKey:)` writes keys.
        var key: String
    }

    private let entries: [Entry]

    init(text: String) {
        entries = text.split(whereSeparator: \.isNewline).compactMap { line in
            var fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = fields.first, !first.hasPrefix("#") else { return nil }
            var marker: String?
            if first.hasPrefix("@") {
                marker = first
                fields.removeFirst()
            }
            guard fields.count >= 3 else { return nil }
            return Entry(marker: marker, hosts: fields[0], key: "\(fields[1]) \(fields[2])")
        }
    }

    static func load(_ files: [URL]) -> OpenSSHKnownHosts {
        OpenSSHKnownHosts(text: files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n"))
    }

    /// What the lists say about `presented` (`type base64`) for `host`, which
    /// is `name` or `[name]:port` as `SFTPEndpoint.hostKeyID` writes it.
    func verdict(for presented: String, host: String) -> Verdict {
        let type = presented.split(separator: " ").first.map(String.init) ?? ""
        var expected: String?
        var others: [String] = []
        for entry in entries where Self.matches(host, entry.hosts) {
            switch entry.marker {
            case "@revoked" where entry.key == presented:
                return .revoked
            case nil where entry.key == presented:
                return .trusted
            case nil where entry.key.hasPrefix(type + " "):
                expected = expected ?? entry.key
            case nil:
                others.append(entry.key)
            default:
                continue
            }
        }
        if let expected { return .changed(expected: expected) }
        return others.isEmpty ? .unknown : .otherKinds(known: others)
    }

    /// Whether `host` is one of the comma-separated `patterns`, or matches
    /// their hash. A matching negated pattern rules the line out.
    static func matches(_ host: String, _ patterns: String) -> Bool {
        if patterns.hasPrefix("|1|") {
            let parts = patterns.split(separator: "|", omittingEmptySubsequences: true)
            guard parts.count == 3, let salt = Data(base64Encoded: String(parts[1])),
                  let hash = Data(base64Encoded: String(parts[2])) else { return false }
            // `ssh` hashes the name in lower case.
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(host.lowercased().utf8), using: SymmetricKey(data: salt))
            return Data(mac) == hash
        }
        var matched = false
        for pattern in patterns.split(separator: ",") {
            if pattern.hasPrefix("!") {
                if glob(pattern.dropFirst(), host) { return false }
            } else if glob(pattern, host) {
                matched = true
            }
        }
        return matched
    }

    /// `*` and `?` only, case-insensitively, as `ssh` matches host patterns;
    /// brackets in `[host]:port` are literal.
    static func glob(_ pattern: Substring, _ text: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let text = Array(text.lowercased())
        func match(_ p: Int, _ t: Int) -> Bool {
            if p == pattern.count { return t == text.count }
            if pattern[p] == "*" {
                return (t...text.count).contains { match(p + 1, $0) }
            }
            guard t < text.count, pattern[p] == "?" || pattern[p] == text[t] else { return false }
            return match(p + 1, t + 1)
        }
        return match(0, 0)
    }
}
