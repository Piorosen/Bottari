import BottariCore
import Citadel
import Crypto
import Foundation
import Synchronization
import NIOCore
import NIOPosix
import NIOSSH

/// Where to connect: one SSH account on one host.
public struct SFTPEndpoint: Hashable, Sendable, Codable {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    /// The host name as `known_hosts` writes it: bare for port 22, `[host]:port` otherwise.
    public var hostKeyID: String {
        port == 22 ? host : "[\(host)]:\(port)"
    }
}

/// How to prove who we are. Secrets stay in memory; callers load them from the Keychain.
public enum SFTPCredential: Equatable, Sendable {
    case password(String)
    /// A private key file's text: OpenSSH format (Ed25519, ECDSA or RSA, with
    /// or without a passphrase) or unencrypted PEM.
    case privateKey(String, passphrase: String? = nil)
    /// Keys held by an SSH agent such as ssh-agent or 1Password; `socket` nil
    /// means `SSH_AUTH_SOCK`. `fallbackKeys` (private key files' text, e.g.
    /// `~/.ssh/id_ed25519`) are tried after the agent's, the way `ssh` falls
    /// back to its default key files; ones that need a passphrase or are of an
    /// unsupported kind are skipped.
    case agent(socket: String? = nil, fallbackKeys: [String] = [])
    /// Tries `first`, then `then` if the server refuses it or it has nothing
    /// to offer: keys first and a password after, as `ssh` does.
    indirect case fallback(SFTPCredential, then: SFTPCredential)

    /// One authentication method per connection attempt, tried in order until
    /// one is accepted.
    func authenticationAttempts(username: String) throws -> [SSHAuthenticationMethod] {
        switch self {
        case .fallback(let first, let then):
            let firstAttempts = (try? first.authenticationAttempts(username: username)) ?? []
            return firstAttempts + (try then.authenticationAttempts(username: username))
        case .password(let password):
            return [.passwordBased(username: username, password: password)]
        case .privateKey(let text, let passphrase):
            return try PrivateKeyFile(text, passphrase: passphrase).attempts(username: username)
        case .agent(let socket, let fallbackKeys):
            var attempts: [SSHAuthenticationMethod] = []
            // Reported only if neither the agent nor the fallback keys leave anything to try.
            let nothingToTry: SFTPConnectError
            if let agent = SSHAgentClient(socket: socket), let offered = agent.attempts(username: username) {
                attempts = offered.attempts
                nothingToTry = offered.held == 0 ? .agentHasNoKeys : .agentHasNoUsableKeys
            } else {
                nothingToTry = .agentUnavailable
            }
            attempts += fallbackKeys.flatMap { text in
                (try? PrivateKeyFile(text, passphrase: nil).attempts(username: username)) ?? []
            }
            guard !attempts.isEmpty else { throw nothingToTry }
            return attempts
        }
    }
}

/// Why a connection could not be opened, in words the UI can show as-is.
public enum SFTPConnectError: Error, Equatable, Sendable {
    /// The server presented a different host key than the one remembered for it.
    case hostKeyChanged(host: String, expected: String, presented: String)
    /// `ssh`'s known_hosts lists the server with a different key.
    case hostKeyChangedInKnownHosts(host: String, expected: String, presented: String)
    /// `ssh`'s known_hosts marks the server's key `@revoked`.
    case hostKeyRevoked(host: String)
    case authenticationFailed
    case unsupportedKey(String)
    /// The key text could not be parsed, or the passphrase is wrong.
    case unreadableKey
    case agentUnavailable
    /// The agent holds no keys at all, and no fallback key file could be used.
    case agentHasNoKeys
    /// The agent holds keys, but none of a kind Bottari can use through it.
    case agentHasNoUsableKeys
    /// A jump host on the way failed; `reason` says how.
    case jumpHostFailed(host: String, reason: String)
    /// Nothing answered at the address before the timeout.
    case noResponse(address: String, seconds: Int)
    /// Something answered, but nothing takes connections on that port.
    case refused(address: String)
    /// The host name does not resolve.
    case unknownHost(String)
    /// This network has no way to reach the host.
    case noRoute(address: String)
    /// The ProxyCommand could not start, or ended before the server answered.
    case proxyCommandFailed(command: String, reason: String)
    case unreachable(String)

    /// `error` as an `SFTPConnectError`, naming `endpoint` when the network was the problem.
    static func wrap(_ error: any Error, dialling endpoint: SFTPEndpoint? = nil) -> any Error {
        if let endpoint, let failure = networkFailure(error, dialling: endpoint) {
            return failure
        }
        switch error {
        case is SFTPConnectError, is CancellationError:
            return error
        case is AuthenticationFailed:
            return SFTPConnectError.authenticationFailed
        case let error as SSHClientError:
            switch error {
            case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication, .unsupportedPrivateKeyAuthentication:
                return SFTPConnectError.authenticationFailed
            default:
                return SFTPConnectError.unreachable(String(describing: error))
            }
        default:
            return SFTPConnectError.unreachable(String(describing: error))
        }
    }

    /// What NIO's socket errors mean for someone trying to reach `endpoint`.
    static func networkFailure(_ error: any Error, dialling endpoint: SFTPEndpoint) -> SFTPConnectError? {
        let address = endpoint.port == 22 ? endpoint.host : "\(endpoint.host):\(endpoint.port)"
        func failure(errno code: CInt) -> SFTPConnectError? {
            switch code {
            case ECONNREFUSED: .refused(address: address)
            case EHOSTUNREACH, ENETUNREACH: .noRoute(address: address)
            default: nil
            }
        }
        switch error {
        case ChannelError.connectTimeout(let timeout):
            return .noResponse(address: address, seconds: Int(timeout.nanoseconds / 1_000_000_000))
        case let error as NIOConnectionError:
            if error.connectionErrors.isEmpty, error.dnsAError != nil || error.dnsAAAAError != nil {
                return .unknownHost(endpoint.host)
            }
            return error.connectionErrors.lazy.compactMap { ($0.error as? IOError).flatMap { failure(errno: $0.errnoCode) } }.first
        case let error as IOError:
            return failure(errno: error.errnoCode)
        default:
            return nil
        }
    }
}

extension SFTPConnectError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .hostKeyChanged(let host, let expected, let presented):
            String(localized: "\(host)의 호스트 키가 변경되었습니다. 서버를 재설치하지 않았다면 연결하지 마십시오.\n저장된 키: \(expected)\n받은 키: \(presented)")
        case .hostKeyChangedInKnownHosts(let host, let expected, let presented):
            String(localized: "\(host)의 호스트 키가 ~/.ssh/known_hosts에 있는 키와 다릅니다. 서버를 재설치하지 않았다면 연결하지 마십시오. 재설치했다면 터미널에서 ssh-keygen -R '\(host)'를 실행한 뒤 다시 연결하십시오.\nknown_hosts의 키: \(expected)\n받은 키: \(presented)")
        case .hostKeyRevoked(let host):
            String(localized: "\(host)의 호스트 키는 ~/.ssh/known_hosts에서 폐기(@revoked)된 키입니다. 연결하지 않았습니다.")
        case .authenticationFailed:
            String(localized: "로그인할 수 없습니다. 사용자 이름과 비밀번호 또는 키를 확인하십시오.")
        case .unsupportedKey(let type):
            String(localized: "지원하지 않는 키 형식입니다: \(type)")
        case .unreadableKey:
            String(localized: "키를 읽을 수 없습니다. 키 형식이나 암호를 확인하십시오.")
        case .agentUnavailable:
            String(localized: "SSH 에이전트에 연결할 수 없고, ~/.ssh에 암호 없이 사용할 수 있는 키 파일(id_ed25519, id_ecdsa, id_rsa)도 없습니다. ssh-agent 또는 1Password 에이전트가 실행 중인지 확인하거나 연결 관리에서 키 파일을 선택하십시오.")
        case .agentHasNoKeys:
            String(localized: "SSH 에이전트에 키가 없고, ~/.ssh에 암호 없이 사용할 수 있는 키 파일(id_ed25519, id_ecdsa, id_rsa)도 없습니다. ssh-add로 키를 추가하거나 연결 관리에서 키 파일을 선택하십시오.")
        case .agentHasNoUsableKeys:
            String(localized: "SSH 에이전트에 사용할 수 있는 키가 없습니다. 에이전트의 키가 인증서나 보안 키(sk-)뿐이라면 일반 키를 ssh-add로 추가하거나 연결 관리에서 키 파일을 선택하십시오.")
        case .jumpHostFailed(let host, let reason):
            String(localized: "점프 호스트 \(host)에서 연결에 실패했습니다. \(reason)")
        case .noResponse(let address, let seconds):
            String(localized: "\(address)에서 \(seconds)초 동안 응답이 없습니다. 서버가 꺼져 있거나, 방화벽 또는 VPN 때문에 이 네트워크에서는 닿지 않을 수 있습니다.")
        case .refused(let address):
            String(localized: "\(address)에서 연결을 거부했습니다. 포트 번호가 맞는지, 서버에서 SSH가 실행 중인지 확인하십시오.")
        case .unknownHost(let host):
            String(localized: "\(host) 주소를 찾을 수 없습니다. 호스트 이름을 확인하고, 사내 주소라면 VPN 연결을 확인하십시오.")
        case .noRoute(let address):
            String(localized: "\(address)로 가는 경로가 없습니다. 네트워크 또는 VPN 연결을 확인하십시오.")
        case .proxyCommandFailed(let command, let reason):
            String(localized: "ProxyCommand로 서버에 닿지 못했습니다: \(command)") + (reason.isEmpty ? "" : "\n\(reason)")
        case .unreachable(let reason):
            String(localized: "서버에 연결할 수 없습니다: \(reason)")
        }
    }
}

/// One SSH server passed through on the way to the destination (ProxyJump).
public struct SSHHop: Equatable, Sendable {
    public var endpoint: SFTPEndpoint
    public var credential: SFTPCredential
    /// How to reach this server when it is the first one dialled: a command
    /// (tokens already filled in) whose standard input and output carry SSH.
    public var proxyCommand: String?

    public init(endpoint: SFTPEndpoint, credential: SFTPCredential, proxyCommand: String? = nil) {
        self.endpoint = endpoint
        self.credential = credential
        self.proxyCommand = proxyCommand
    }
}

/// The open SSH connection, its SFTP channel, and any jump hosts it runs through.
///
/// `SSHClient` is not marked `Sendable`, but its state lives on its NIO event
/// loop and we only call its async methods, which hop onto that loop.
///
/// Each connection gets its own event loop thread: an agent waiting for the
/// user to approve a signature blocks that thread, and should stall only the
/// connection asking for it.
final class SFTPConnection: @unchecked Sendable {
    let client: SSHClient
    let sftp: SFTPClient
    /// The channel the destination's SSH session runs on, for what Citadel
    /// does not offer, such as forwarding an agent.
    let channel: Channel
    /// When the destination server last sent anything.
    let heartbeat: Heartbeat
    /// Jump host connections, outermost first; closed after the destination.
    private let jumps: [SSHClient]
    private let group: MultiThreadedEventLoopGroup
    /// Requests sent outside any caller's await (read-ahead, closing an abandoned
    /// file). Closing waits for them: a request sent while the channel goes down
    /// would never be answered, which Citadel treats as a fatal leak.
    private let background = Mutex<(closing: Bool, next: Int, tasks: [Int: Task<Void, Never>])>((false, 0, [:]))
    private let keepAlive = Mutex<Task<Void, Never>?>(nil)

    /// How long the server may stay quiet before it is asked whether it is still
    /// there, like `ServerAliveInterval`, and how long it then has to answer.
    static let keepAliveInterval: Duration = .seconds(30)
    static let keepAliveTimeout: Duration = .seconds(20)

    private init(client: SSHClient, sftp: SFTPClient, channel: Channel, heartbeat: Heartbeat, jumps: [SSHClient], group: MultiThreadedEventLoopGroup) {
        self.client = client
        self.sftp = sftp
        self.channel = channel
        self.heartbeat = heartbeat
        self.jumps = jumps
        self.group = group
    }

    /// Connects through `hops` in order (the first is dialled directly, or
    /// through its ProxyCommand), then to `endpoint`; with no hops,
    /// `proxyCommand` is how to reach `endpoint`.
    static func open(
        to endpoint: SFTPEndpoint,
        credential: SFTPCredential,
        hostKeys: HostKeyTrust,
        via hops: [SSHHop] = [],
        proxyCommand: String? = nil,
        timeout: TimeAmount = .seconds(15)
    ) async throws -> SFTPConnection {
        let route = hops.isEmpty
            ? (proxyCommand.map { " (ProxyCommand: \($0))" } ?? "")
            : String(localized: " (경유: ") + hops.map { "\($0.endpoint.username)@\($0.endpoint.hostKeyID)" }.joined(separator: " → ") + ")"
        Log.connection.info("연결 시작: \(endpoint.username)@\(endpoint.hostKeyID)\(route)")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var chain: [SSHClient] = []
        do {
            for hop in hops {
                do {
                    chain.append(try await connect(hop, through: chain.last, hostKeys: hostKeys, group: group, timeout: timeout).client)
                } catch let error as SFTPConnectError {
                    switch error {
                    case .hostKeyChanged, .hostKeyChangedInKnownHosts, .hostKeyRevoked: throw error
                    default: break
                    }
                    throw SFTPConnectError.jumpHostFailed(host: hop.endpoint.hostKeyID, reason: error.localizedDescription)
                }
            }
            let (destination, channel, heartbeat) = try await connect(
                SSHHop(endpoint: endpoint, credential: credential, proxyCommand: proxyCommand),
                through: chain.last,
                hostKeys: hostKeys,
                group: group,
                timeout: timeout
            )
            do {
                let connection = SFTPConnection(
                    client: destination,
                    sftp: try await destination.openSFTP(),
                    channel: channel,
                    heartbeat: heartbeat,
                    jumps: chain,
                    group: group
                )
                connection.startKeepAlive()
                Log.connection.info("연결됨: \(endpoint.username)@\(endpoint.hostKeyID)")
                return connection
            } catch {
                try? await destination.close()
                throw SFTPConnectError.wrap(error)
            }
        } catch {
            for client in chain.reversed() {
                try? await client.close()
            }
            try? await group.shutdownGracefully()
            let reason = SFTPConnectError.wrap(error)
            Log.connection.error("연결 실패: \(endpoint.username)@\(endpoint.hostKeyID): \(reason.localizedDescription)")
            throw reason
        }
    }

    /// Opens one SSH session, over TCP or inside a direct-tcpip channel of
    /// `previous`, trying each authentication attempt the credential offers.
    /// Bottari opens the channel itself either way, so it can hear every byte
    /// the server sends and tell a quiet connection from a dead one.
    private static func connect(
        _ hop: SSHHop,
        through previous: SSHClient?,
        hostKeys: HostKeyTrust,
        group: MultiThreadedEventLoopGroup,
        timeout: TimeAmount
    ) async throws -> (client: SSHClient, channel: Channel, heartbeat: Heartbeat) {
        let attempts = try hop.credential.authenticationAttempts(username: hop.endpoint.username)
        for (index, method) in attempts.enumerated() {
            var opened: Channel?
            var proxy: ProxyCommand?
            do {
                let heartbeat = Heartbeat()
                let channel: Channel
                (channel, proxy) = try await openChannel(to: hop, through: previous, group: group, timeout: timeout, heartbeat: heartbeat)
                opened = channel
                let tracker = AuthenticationTracker(method, channel: channel)
                let attempt = UncheckedSendable(SSHAuthenticationMethod.custom(tracker))
                do {
                    // Citadel adds the session's handlers synchronously, which NIO
                    // only allows on the channel's own event loop, so run the call there.
                    let client = try await withTaskExecutorPreference(EventLoopTaskExecutor(channel.eventLoop)) {
                        try await SSHClient.connect(
                            on: channel,
                            settings: SSHClientSettings(
                                host: hop.endpoint.host,
                                port: hop.endpoint.port,
                                authenticationMethod: { attempt.value },
                                hostKeyValidator: hostKeys.validator(for: hop.endpoint)
                            )
                        )
                    }
                    return (client, channel, heartbeat)
                } catch {
                    if tracker.isExhausted { throw SFTPConnectError.authenticationFailed }
                    throw error
                }
            } catch {
                try? await opened?.close()
                let reason = SFTPConnectError.wrap(hostKeys.rejection(for: hop.endpoint) ?? error, dialling: hop.endpoint)
                if case SFTPConnectError.authenticationFailed = reason {
                    Log.connection.info("\(hop.endpoint.hostKeyID): 인증 방법 \(index + 1)/\(attempts.count) 거부됨")
                    continue
                }
                if let proxy, case SFTPConnectError.unreachable = reason {
                    // The command's own words say more than a closed pipe does.
                    throw SFTPConnectError.proxyCommandFailed(command: proxy.command, reason: proxy.errorOutput)
                }
                throw reason
            }
        }
        throw SFTPConnectError.authenticationFailed
    }

    /// A TCP connection to the hop, a channel to it through `previous`, or
    /// its ProxyCommand's standard input and output, ready for Citadel to
    /// start SSH on.
    private static func openChannel(
        to hop: SSHHop,
        through previous: SSHClient?,
        group: MultiThreadedEventLoopGroup,
        timeout: TimeAmount,
        heartbeat: Heartbeat
    ) async throws -> (Channel, ProxyCommand?) {
        let endpoint = hop.endpoint
        // Runs on the loop before any data arrives.
        let prepare: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers(heartbeat.listener(), HoldUntilSSHStarts())
            }
        }
        if let previous {
            let channel = try await previous.createDirectTCPIPChannel(
                using: .init(
                    targetHost: endpoint.host,
                    targetPort: endpoint.port,
                    originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                ),
                initialize: prepare
            )
            return (channel, nil)
        }
        if let command = hop.proxyCommand {
            let (channel, process) = try await ProxyCommand.start(command, group: group, prepare: prepare)
            return (channel, process)
        }
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer(prepare)
            .connect(host: endpoint.host, port: endpoint.port)
            .get()
        return (channel, nil)
    }

    /// Runs `operation` as tracked background work, or returns nil once closing has begun.
    @discardableResult
    func track<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Task<T, any Error>? {
        background.withLock { state in
            guard !state.closing else { return nil }
            let id = state.next
            state.next += 1
            let task = Task {
                defer { self.background.withLock { _ = $0.tasks.removeValue(forKey: id) } }
                return try await operation()
            }
            state.tasks[id] = Task { _ = try? await task.value }
            return task
        }
    }

    /// Whether the server answers a small request within `limit`. Any other
    /// bytes from it in the meantime count too: a reply can queue behind a
    /// download, and a server sending a download is plainly there.
    func ping(within limit: Duration) async -> Bool {
        let sent = ContinuousClock.now
        let outcome = FirstAnswer()
        return await withCheckedContinuation { continuation in
            outcome.wait(with: continuation)
            guard let request = track({ try await self.sftp.getRealPath(atPath: ".") }) else {
                outcome.give(false)
                return
            }
            Task { outcome.give((try? await request.value) != nil) }
            Task { [heartbeat] in
                try? await Task.sleep(for: limit)
                outcome.give(heartbeat.heard(since: sent))
            }
        }
    }

    /// Asks a quiet server whether it is still there and closes the connection
    /// when it does not answer. A Mac waking from sleep or moving to another
    /// network leaves connections that look open but go nowhere; every request
    /// on one would hang until TCP gave up, minutes later.
    private func startKeepAlive() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.client.isConnected else { return }
                guard self.heartbeat.quiet >= Self.keepAliveInterval else { continue }
                if await !self.ping(within: Self.keepAliveTimeout) {
                    Log.connection.error("서버가 \(Self.keepAliveTimeout) 동안 응답하지 않아 연결을 닫음")
                    await self.close()
                    return
                }
            }
        }
        keepAlive.withLock { $0 = task }
    }

    func close() async {
        let pending: [Task<Void, Never>]? = background.withLock { state in
            guard !state.closing else { return nil }
            state.closing = true
            return Array(state.tasks.values)
        }
        guard let pending else { return }
        keepAlive.withLock { $0?.cancel() }
        // Give tracked requests their answers first, for two seconds at most.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for task in pending { await task.value }
            }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
        try? await sftp.close()
        try? await client.close()
        for jump in jumps.reversed() {
            try? await jump.close()
        }
        try? await group.shutdownGracefully()
    }
}

/// When a server last sent anything: any bytes at all, so a long download
/// counts as much as an answered keepalive.
final class Heartbeat: Sendable {
    private let last = Mutex(ContinuousClock.now)

    /// How long the server has been silent. The clock keeps running while the
    /// Mac sleeps, so a connection from before a nap looks as quiet as it is.
    var quiet: Duration {
        .now - last.withLock { $0 }
    }

    func heard(since instant: ContinuousClock.Instant) -> Bool {
        last.withLock { $0 } > instant
    }

    func beat() {
        last.withLock { $0 = .now }
    }

    /// A handler for the bottom of the connection's pipeline.
    func listener() -> some ChannelHandler & Sendable {
        Listener(heartbeat: self)
    }

    private final class Listener: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer
        let heartbeat: Heartbeat

        init(heartbeat: Heartbeat) {
            self.heartbeat = heartbeat
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            heartbeat.beat()
            context.fireChannelRead(data)
        }
    }
}

/// Resumes a continuation with whichever answer comes first.
final class FirstAnswer: Sendable {
    private let continuation = Mutex<CheckedContinuation<Bool, Never>?>(nil)

    func wait(with continuation: CheckedContinuation<Bool, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func give(_ answer: Bool) {
        let waiting = continuation.withLock { current in
            defer { current = nil }
            return current
        }
        waiting?.resume(returning: answer)
    }
}

/// Holds bytes that arrive on a jump channel before the SSH handler is in place.
///
/// The target server sends its version line as soon as the channel opens, but
/// Citadel adds the SSH handler only afterwards; without this, that line could
/// fall off the end of the pipeline and the handshake would stall. The SSH
/// handler announces itself by writing its own version line, which is the cue to
/// replay what was held.
private final class HoldUntilSSHStarts: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var held: [ByteBuffer] = []
    private var started = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard started else {
            held.append(unwrapInboundIn(data))
            return
        }
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if started { context.fireChannelReadComplete() }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
        guard !started else { return }
        started = true
        let replay = held
        held = []
        for bytes in replay {
            context.fireChannelRead(wrapInboundOut(bytes))
        }
        if !replay.isEmpty { context.fireChannelReadComplete() }
    }
}

/// Watches a login inside a jump host channel. NIOSSH reports a rejected login as
/// a pipeline error, but nothing in a nested session closes the channel on it, so
/// Citadel would wait for its 10 second login timeout. On the first offer this adds
/// a handler that closes the channel on such an error and remembers why.
final class AuthenticationTracker: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let method: SSHAuthenticationMethod
    private let channel: Channel
    private let lock = NSLock()
    private var exhausted = false
    private var watching = false

    init(_ method: SSHAuthenticationMethod, channel: Channel) {
        self.method = method
        self.channel = channel
    }

    var isExhausted: Bool {
        lock.withLock { exhausted }
    }

    func markExhausted() {
        lock.withLock { exhausted = true }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Called on the channel's event loop, after the SSH handlers are in place.
        if !watching {
            watching = true
            try? channel.pipeline.syncOperations.addHandler(LoginFailureWatcher(tracker: self))
        }
        method.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: nextChallengePromise)
    }
}

private final class LoginFailureWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let tracker: AuthenticationTracker

    init(tracker: AuthenticationTracker) {
        self.tracker = tracker
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if error is SSHClientError || error is AuthenticationFailed {
            tracker.markExhausted()
            context.close(promise: nil)
        }
        context.fireErrorCaught(error)
    }
}

/// Runs Swift tasks on a NIO event loop, so `nonisolated async` library code that
/// touches a channel pipeline synchronously executes on the loop that owns it.
final class EventLoopTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let eventLoop: any EventLoop

    init(_ eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        eventLoop.execute {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}

/// Carries a value NIO only touches on one event loop across a `@Sendable` boundary.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
