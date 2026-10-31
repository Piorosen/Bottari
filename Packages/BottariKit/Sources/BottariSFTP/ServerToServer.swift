import BottariCore
import Foundation

/// What another server needs to send files straight to a server: where it
/// is, the jump hosts on the way, the agent to log in with, and the host keys
/// to expect, so nothing is trusted on first use there.
struct DirectReach: Sendable {
    let endpoint: SFTPEndpoint
    let hops: [SFTPEndpoint]
    let agent: ForwardedAgent
    /// known_hosts lines for every server on the way; nil when the connection
    /// accepted any key (tests only), which the copy then does too.
    let knownHosts: [String]?

    /// Nil when the login cannot be forwarded: a password, or keys of several
    /// kinds (an agent and key files) that one forwarded agent cannot offer.
    init?(endpoint: SFTPEndpoint, credential: SFTPCredential, hops: [SSHHop], hostKeys: HostKeyTrust) {
        guard let agent = Self.agent(for: hops.map(\.credential) + [credential]) else { return nil }
        self.endpoint = endpoint
        self.hops = hops.map(\.endpoint)
        self.agent = agent
        let lines = (hops.map(\.endpoint) + [endpoint]).map(hostKeys.knownHostsLine(for:))
        knownHosts = lines.contains(nil) ? nil : lines.compactMap { $0 }
    }

    private static func agent(for credentials: [SFTPCredential]) -> ForwardedAgent? {
        var socket: String?
        var keys: [PrivateKeyFile] = []
        func add(_ credential: SFTPCredential) -> Bool {
            switch credential {
            case .password:
                return false
            case .privateKey(let text, let passphrase):
                guard let key = try? PrivateKeyFile(text, passphrase: passphrase) else { return false }
                keys.append(key)
                return true
            case .agent(let path, let fallbackKeys):
                if let path = path ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], FileManager.default.fileExists(atPath: path) {
                    guard socket == nil || socket == path else { return false }
                    socket = path
                    return true
                }
                let files = fallbackKeys.compactMap { try? PrivateKeyFile($0, passphrase: nil) }
                keys += files
                return !files.isEmpty
            case .fallback(let first, _):
                return add(first)
            }
        }
        for credential in credentials {
            guard add(credential) else { return nil }
        }
        switch (socket, keys.isEmpty) {
        case (let socket?, true): return .socket(socket)
        case (nil, false): return .keys(keys)
        default: return nil
        }
    }
}

/// Why a server-to-server copy did not happen.
public enum DirectCopyError: Error, LocalizedError {
    /// The source server could not reach or log in to the destination; going
    /// through the Mac still can.
    case unreachable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let reason): String(localized: "원본 서버에서 대상 서버에 연결할 수 없습니다: \(reason)")
        case .failed(let reason): String(localized: "서버 간 직접 전송에 실패했습니다: \(reason)")
        }
    }
}

extension SFTPFileProvider {
    /// Whether this server can send files straight to `destination`: it runs
    /// commands, and the login to `destination` can be lent to it.
    public func canSend(directlyTo destination: SFTPFileProvider) -> Bool {
        canRunCommands && destination.directReach != nil && locationID != destination.locationID
    }

    /// Copies `items`, all in one folder here, into `folder` on `destination`
    /// with tar on this server, which logs in there with the Mac's agent (or
    /// the key Bottari holds) forwarded for the length of the copy. The bytes
    /// never pass through the Mac.
    public func send(_ items: [FileItem], directlyTo destination: SFTPFileProvider, into folder: RemotePath) async throws {
        guard let reach = destination.directReach, let parent = items.first?.path.parent else {
            throw ProviderError.unsupported(String(localized: "서버 간 직접 전송"))
        }
        let connection = try await link.openAnother()
        defer { Task { await connection.close() } }
        let command = Self.directCopyCommand(names: items.map(\.name), from: parent, to: folder, reach: reach)
        Log.transfer.info("서버 간 직접 전송: \(endpoint.hostKeyID):\(parent.string) → \(reach.endpoint.hostKeyID):\(folder.string), \(items.count)개 항목")
        let result = try await connection.run("/bin/sh -c " + Self.quote(command), forwarding: reach.agent)
        let message = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.exitStatus {
        case 0?:
            return
        case 255?, 70?, 126?, 127?:
            // ssh's own failures (no route, refused, a host key or login
            // problem), or no ssh, tar or mktemp on the source at all.
            throw DirectCopyError.unreachable(message)
        default:
            throw DirectCopyError.failed(message.isEmpty ? String(localized: "종료 코드 \(result.exitStatus.map(String.init) ?? "?")") : message)
        }
    }

    /// The shell script the source runs: tar the items, pipe them to tar on
    /// the destination over ssh, and exit with whichever side failed.
    ///
    /// Jump hosts are chained with explicit ProxyCommands rather than `-J`,
    /// which would check their keys against the source's own known_hosts and
    /// ask about unknown ones with nobody to answer. If the channel closes
    /// (the copy was cancelled), everything the script started is stopped.
    static func directCopyCommand(names: [String], from parent: RemotePath, to folder: RemotePath, reach: DirectReach) -> String {
        let ssh = sshCommand(to: reach.endpoint, through: reach.hops, checkingKeys: reach.knownHosts != nil)
            + " " + quote("tar -C \(quote(folder.string)) -xpf -")
        let lines = (reach.knownHosts ?? []).map(quote).joined(separator: " ")
        return """
        command -v ssh >/dev/null && command -v tar >/dev/null || exit 127
        kh=$(mktemp) && st=$(mktemp) || exit 70
        export kh
        trap 'rm -f "$kh" "$st"' EXIT
        trap 'exit 143' TERM
        ( cat >/dev/null; kill 0 ) </dev/stdin >/dev/null 2>&1 &
        printf '%s\\n' \(lines) > "$kh"
        ( tar -C \(quote(parent.string)) -cf - -- \(names.map(quote).joined(separator: " ")); echo $? > "$st" ) | \(ssh)
        s=$?
        [ "$s" -eq 0 ] || exit "$s"
        t=$(cat "$st")
        exit "${t:-1}"
        """
    }

    /// `ssh` to `target` through `hops`, each hop reached by the ProxyCommand
    /// of the one after it, all with the same strict options.
    static func sshCommand(to target: SFTPEndpoint, through hops: [SFTPEndpoint], checkingKeys: Bool) -> String {
        sshOptions(through: hops, checkingKeys: checkingKeys) + " " + destination(target)
    }

    private static func sshOptions(through hops: [SFTPEndpoint], checkingKeys: Bool) -> String {
        // "$kh" stays unquoted so each shell along the way expands it.
        let keys = checkingKeys
            ? "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=\"$kh\""
            : "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        var command = "ssh -F /dev/null -o BatchMode=yes -o ForwardAgent=no -o ClearAllForwardings=yes -o LogLevel=ERROR -o ConnectTimeout=15 -o GlobalKnownHostsFile=/dev/null \(keys)"
        if let last = hops.last {
            // This ssh fills %h and %p in its ProxyCommand with the target, for
            // -W to relay to. Everything else in it is the hop's, so its "%"
            // are doubled to come through for the hop's own ssh to expand.
            let reachHop = sshOptions(through: Array(hops.dropLast()), checkingKeys: checkingKeys).replacingOccurrences(of: "%", with: "%%")
            command += " -o " + quote("ProxyCommand=\(reachHop) -W %h:%p \(destination(last).replacingOccurrences(of: "%", with: "%%"))")
        }
        return command
    }

    private static func destination(_ endpoint: SFTPEndpoint) -> String {
        "-p \(endpoint.port) -l \(quote(endpoint.username)) -- \(quote(endpoint.host))"
    }
}
