import Citadel
import Crypto
import Foundation
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
    /// An OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----`), Ed25519 or RSA.
    case privateKey(String, passphrase: String? = nil)
    /// Keys held by an SSH agent such as ssh-agent or 1Password; `socket` nil
    /// means `SSH_AUTH_SOCK`. Only the agent's Ed25519 keys are used for now.
    case agent(socket: String? = nil)

    /// One authentication method per connection attempt, tried in order until one
    /// is accepted. Only an agent with several keys yields more than one.
    func authenticationAttempts(username: String) throws -> [SSHAuthenticationMethod] {
        guard case .agent(let socket) = self else {
            return [try authenticationMethod(username: username)]
        }
        guard let agent = SSHAgentClient(socket: socket), let identities = try? agent.identities() else {
            throw SFTPConnectError.agentUnavailable
        }
        let keys = identities.compactMap { AgentEd25519PrivateKey(agent: agent, identity: $0) }
        guard !keys.isEmpty else { throw SFTPConnectError.agentHasNoUsableKeys }
        return keys.map { .custom(SingleKeyOffer(username: username, key: NIOSSHPrivateKey(custom: $0))) }
    }

    func authenticationMethod(username: String) throws -> SSHAuthenticationMethod {
        switch self {
        case .agent:
            preconditionFailure("Agent credentials go through authenticationAttempts(username:)")
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .privateKey(let text, let passphrase):
            let decryptionKey = passphrase.map { Data($0.utf8) }
            let type: SSHKeyType
            do {
                type = try SSHKeyDetection.detectPrivateKeyType(from: text)
            } catch {
                throw SFTPConnectError.unreadableKey
            }
            do {
                switch type {
                case .ed25519:
                    let key = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryptionKey)
                    return .ed25519(username: username, privateKey: key)
                case .rsa:
                    let key = try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryptionKey)
                    return .rsa(username: username, privateKey: key)
                default:
                    throw SFTPConnectError.unsupportedKey(type.description)
                }
            } catch let error as SFTPConnectError {
                throw error
            } catch {
                throw SFTPConnectError.unreadableKey
            }
        }
    }
}

/// Why a connection could not be opened, in words the UI can show as-is.
public enum SFTPConnectError: Error, Equatable, Sendable {
    /// The server presented a different host key than the one remembered for it.
    case hostKeyChanged(host: String, expected: String, presented: String)
    case authenticationFailed
    case unsupportedKey(String)
    /// The key text could not be parsed, or the passphrase is wrong.
    case unreadableKey
    case agentUnavailable
    case agentHasNoUsableKeys
    /// A jump host on the way failed; `reason` says how.
    case jumpHostFailed(host: String, reason: String)
    case unreachable(String)

    static func wrap(_ error: any Error) -> any Error {
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
}

extension SFTPConnectError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .hostKeyChanged(let host, let expected, let presented):
            "\(host)의 호스트 키가 바뀌었어요. 서버를 다시 설치한 게 아니라면 연결하지 마세요.\n저장된 키: \(expected)\n받은 키: \(presented)"
        case .authenticationFailed:
            "로그인하지 못했어요. 사용자 이름과 비밀번호 또는 키를 확인하세요."
        case .unsupportedKey(let type):
            "아직 지원하지 않는 키 형식이에요: \(type)"
        case .unreadableKey:
            "키를 읽지 못했어요. 형식이나 암호를 확인하세요."
        case .agentUnavailable:
            "SSH 에이전트에 연결하지 못했어요. ssh-agent 나 1Password 에이전트가 켜져 있는지 확인하세요."
        case .agentHasNoUsableKeys:
            "에이전트에 쓸 수 있는 키가 없어요. Ed25519 키를 ssh-add 로 추가하세요. (RSA · ECDSA 에이전트 키는 아직 지원하지 않아요)"
        case .jumpHostFailed(let host, let reason):
            "점프 호스트 \(host)에서 막혔어요. \(reason)"
        case .unreachable(let reason):
            "서버에 연결하지 못했어요: \(reason)"
        }
    }
}

/// One SSH server passed through on the way to the destination (ProxyJump).
public struct SSHHop: Equatable, Sendable {
    public var endpoint: SFTPEndpoint
    public var credential: SFTPCredential

    public init(endpoint: SFTPEndpoint, credential: SFTPCredential) {
        self.endpoint = endpoint
        self.credential = credential
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
    /// Jump host connections, outermost first; closed after the destination.
    private let jumps: [SSHClient]
    private let group: MultiThreadedEventLoopGroup

    private init(client: SSHClient, sftp: SFTPClient, jumps: [SSHClient], group: MultiThreadedEventLoopGroup) {
        self.client = client
        self.sftp = sftp
        self.jumps = jumps
        self.group = group
    }

    /// Connects through `hops` in order (the first is dialled directly), then to `endpoint`.
    static func open(
        to endpoint: SFTPEndpoint,
        credential: SFTPCredential,
        hostKeys: HostKeyTrust,
        via hops: [SSHHop] = [],
        timeout: TimeAmount = .seconds(15)
    ) async throws -> SFTPConnection {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var chain: [SSHClient] = []
        do {
            for hop in hops {
                do {
                    chain.append(try await connect(hop, through: chain.last, hostKeys: hostKeys, group: group, timeout: timeout))
                } catch let error as SFTPConnectError {
                    if case .hostKeyChanged = error { throw error }
                    throw SFTPConnectError.jumpHostFailed(host: hop.endpoint.hostKeyID, reason: error.localizedDescription)
                }
            }
            let destination = try await connect(
                SSHHop(endpoint: endpoint, credential: credential),
                through: chain.last,
                hostKeys: hostKeys,
                group: group,
                timeout: timeout
            )
            do {
                return SFTPConnection(client: destination, sftp: try await destination.openSFTP(), jumps: chain, group: group)
            } catch {
                try? await destination.close()
                throw SFTPConnectError.wrap(error)
            }
        } catch {
            for client in chain.reversed() {
                try? await client.close()
            }
            try? await group.shutdownGracefully()
            throw SFTPConnectError.wrap(error)
        }
    }

    /// Opens one SSH session, directly or inside a direct-tcpip channel of
    /// `previous`, trying each authentication attempt the credential offers.
    private static func connect(
        _ hop: SSHHop,
        through previous: SSHClient?,
        hostKeys: HostKeyTrust,
        group: MultiThreadedEventLoopGroup,
        timeout: TimeAmount
    ) async throws -> SSHClient {
        for method in try hop.credential.authenticationAttempts(username: hop.endpoint.username) {
            do {
                guard let previous else {
                    return try await SSHClient.connect(
                        host: hop.endpoint.host,
                        port: hop.endpoint.port,
                        authenticationMethod: method,
                        hostKeyValidator: hostKeys.validator(for: hop.endpoint),
                        reconnect: .never,
                        group: group,
                        connectTimeout: timeout
                    )
                }
                let channel = try await previous.createDirectTCPIPChannel(
                    using: .init(
                        targetHost: hop.endpoint.host,
                        targetPort: hop.endpoint.port,
                        originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                    )
                ) { channel in
                    // Runs on the loop before any data arrives.
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(HoldUntilSSHStarts())
                    }
                }
                let tracker = AuthenticationTracker(method, channel: channel)
                let attempt = UncheckedSendable(SSHAuthenticationMethod.custom(tracker))
                do {
                    // Citadel adds the nested session's handlers synchronously, which NIO
                    // only allows on the channel's own event loop, so run the call there.
                    return try await withTaskExecutorPreference(EventLoopTaskExecutor(channel.eventLoop)) {
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
                } catch {
                    if tracker.isExhausted { throw SFTPConnectError.authenticationFailed }
                    throw error
                }
            } catch {
                let reason = SFTPConnectError.wrap(hostKeys.rejection(for: hop.endpoint) ?? error)
                if case SFTPConnectError.authenticationFailed = reason { continue }
                throw reason
            }
        }
        throw SFTPConnectError.authenticationFailed
    }

    func close() async {
        try? await sftp.close()
        try? await client.close()
        for jump in jumps.reversed() {
            try? await jump.close()
        }
        try? await group.shutdownGracefully()
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
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
