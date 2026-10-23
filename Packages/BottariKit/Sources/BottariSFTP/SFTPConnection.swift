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
public enum SFTPCredential: Sendable {
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
        case .unreachable(let reason):
            "서버에 연결하지 못했어요: \(reason)"
        }
    }
}

/// The open SSH connection and its SFTP channel.
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
    private let group: MultiThreadedEventLoopGroup

    private init(client: SSHClient, sftp: SFTPClient, group: MultiThreadedEventLoopGroup) {
        self.client = client
        self.sftp = sftp
        self.group = group
    }

    static func open(
        to endpoint: SFTPEndpoint,
        credential: SFTPCredential,
        hostKeys: HostKeyTrust,
        timeout: TimeAmount = .seconds(15)
    ) async throws -> SFTPConnection {
        for method in try credential.authenticationAttempts(username: endpoint.username) {
            do {
                return try await open(to: endpoint, method: method, hostKeys: hostKeys, timeout: timeout)
            } catch SFTPConnectError.authenticationFailed {
                continue
            }
        }
        throw SFTPConnectError.authenticationFailed
    }

    private static func open(
        to endpoint: SFTPEndpoint,
        method: SSHAuthenticationMethod,
        hostKeys: HostKeyTrust,
        timeout: TimeAmount
    ) async throws -> SFTPConnection {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: endpoint.host,
                port: endpoint.port,
                authenticationMethod: method,
                hostKeyValidator: hostKeys.validator(for: endpoint),
                reconnect: .never,
                group: group,
                connectTimeout: timeout
            )
        } catch {
            try? await group.shutdownGracefully()
            throw SFTPConnectError.wrap(hostKeys.rejection(for: endpoint) ?? error)
        }
        do {
            return SFTPConnection(client: client, sftp: try await client.openSFTP(), group: group)
        } catch {
            try? await client.close()
            try? await group.shutdownGracefully()
            throw SFTPConnectError.wrap(error)
        }
    }

    func close() async {
        try? await sftp.close()
        try? await client.close()
        try? await group.shutdownGracefully()
    }
}
