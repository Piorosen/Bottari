import Crypto
import Foundation
import NIOCore
import NIOSSH

/// A client for the SSH agent protocol (ssh-agent, 1Password, Secretive) over
/// the agent's Unix socket. Requests are short and blocking.
struct SSHAgentClient: Sendable {
    struct Identity: Equatable, Sendable {
        /// The public key in SSH wire format: `string type, …`.
        let blob: Data
        let comment: String

        var keyType: String {
            var wire = SSHWire(blob)
            return (try? wire.readString()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    let socketPath: String

    /// The agent named by `path`, or by `SSH_AUTH_SOCK` when `path` is nil.
    init?(socket path: String?, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let resolved = path ?? environment["SSH_AUTH_SOCK"], !resolved.isEmpty else { return nil }
        socketPath = resolved
    }

    func identities() throws -> [Identity] {
        var reply = SSHWire(try request(Data([Message.requestIdentities]), timeout: 5))
        guard try reply.readByte() == Message.identitiesAnswer else { throw SSHAgentError.unexpectedReply }
        return try (0..<reply.readUInt32()).map { _ in
            Identity(blob: try reply.readString(), comment: String(decoding: try reply.readString(), as: UTF8.self))
        }
    }

    /// Asks the agent to sign `data` with the key whose public blob is `blob`.
    /// Returns the signature in wire format: `string type, string signature`.
    func sign(_ data: Data, with blob: Data, flags: UInt32 = 0) throws -> Data {
        var payload = Data([Message.signRequest])
        payload.appendSSHString(blob)
        payload.appendSSHString(data)
        payload.appendUInt32(flags)
        // Agents such as 1Password may wait for the user to approve.
        var reply = SSHWire(try request(payload, timeout: 120))
        switch try reply.readByte() {
        case Message.signResponse: return try reply.readString()
        case Message.failure: throw SSHAgentError.refused
        default: throw SSHAgentError.unexpectedReply
        }
    }

    private enum Message {
        static let failure: UInt8 = 5
        static let requestIdentities: UInt8 = 11
        static let identitiesAnswer: UInt8 = 12
        static let signRequest: UInt8 = 13
        static let signResponse: UInt8 = 14
    }

    private func request(_ payload: Data, timeout seconds: Int) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHAgentError.unavailable(socketPath) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SSHAgentError.unavailable(socketPath) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SSHAgentError.unavailable(socketPath) }

        var message = Data()
        message.appendUInt32(UInt32(payload.count))
        message.append(payload)
        try message.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                guard n > 0 else { throw SSHAgentError.unavailable(socketPath) }
                sent += n
            }
        }
        var header = SSHWire(try readExactly(fd, 4))
        let length = try header.readUInt32()
        guard length > 0, length < 256 * 1024 else { throw SSHAgentError.unexpectedReply }
        return try readExactly(fd, Int(length))
    }

    private func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var received = 0
        try data.withUnsafeMutableBytes { buffer in
            while received < count {
                let n = read(fd, buffer.baseAddress! + received, count - received)
                guard n > 0 else { throw SSHAgentError.unexpectedReply }
                received += n
            }
        }
        return data
    }
}

enum SSHAgentError: Error, Equatable {
    case unavailable(String)
    case refused
    case unexpectedReply
}

// MARK: - Agent-held Ed25519 keys for NIOSSH

/// An Ed25519 key whose private half stays in the agent; NIOSSH asks it to sign.
/// On the wire it is indistinguishable from a normal `ssh-ed25519` key.
struct AgentEd25519PrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = "ssh-ed25519"

    let agent: SSHAgentClient
    let identity: SSHAgentClient.Identity
    let rawPublicKey: Data

    init?(agent: SSHAgentClient, identity: SSHAgentClient.Identity) {
        var wire = SSHWire(identity.blob)
        guard let type = try? wire.readString(), type == Data(Self.keyPrefix.utf8),
              let raw = try? wire.readString(), raw.count == 32 else { return nil }
        self.agent = agent
        self.identity = identity
        self.rawPublicKey = raw
    }

    var publicKey: NIOSSHPublicKeyProtocol {
        AgentEd25519PublicKey(rawRepresentation: rawPublicKey)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        var reply = SSHWire(try agent.sign(Data(data), with: identity.blob))
        guard try reply.readString() == Data(Self.keyPrefix.utf8) else { throw SSHAgentError.unexpectedReply }
        return AgentEd25519Signature(rawRepresentation: try reply.readString())
    }
}

struct AgentEd25519PublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "ssh-ed25519"
    let rawRepresentation: Data

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawRepresentation) else { return false }
        return key.isValidSignature(signature.rawRepresentation, for: data)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> AgentEd25519PublicKey {
        AgentEd25519PublicKey(rawRepresentation: try buffer.readSSHString())
    }
}

struct AgentEd25519Signature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "ssh-ed25519"
    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> AgentEd25519Signature {
        AgentEd25519Signature(rawRepresentation: try buffer.readSSHString())
    }
}

/// Offers exactly one key. Citadel asks a custom delegate only once, so trying
/// several agent keys means one connection attempt per key.
final class SingleKeyOffer: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: NIOSSHPrivateKey

    init(username: String, key: NIOSSHPrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // NIOSSH calls delegates on the connection's event loop.
        let promise = nextChallengePromise.assumeIsolated()
        guard availableMethods.contains(.publicKey) else {
            promise.succeed(nil)
            return
        }
        promise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key)))
        )
    }
}

// MARK: - SSH wire format

/// Reads the SSH binary encoding: big-endian integers and length-prefixed strings.
struct SSHWire {
    private var data: Data
    private var offset: Data.Index

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.endIndex else { throw SSHAgentError.unexpectedReply }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard data.endIndex - offset >= 4 else { throw SSHAgentError.unexpectedReply }
        let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard data.endIndex - offset >= length else { throw SSHAgentError.unexpectedReply }
        defer { offset += length }
        return Data(data[offset..<offset + length])
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendSSHString(_ bytes: Data) {
        appendUInt32(UInt32(bytes.count))
        append(bytes)
    }
}

extension ByteBuffer {
    @discardableResult
    mutating func writeSSHString(_ bytes: Data) -> Int {
        writeInteger(UInt32(bytes.count)) + writeBytes(bytes)
    }

    mutating func readSSHString() throws -> Data {
        guard let length = readInteger(as: UInt32.self), let bytes = readBytes(length: Int(length)) else {
            throw SSHAgentError.unexpectedReply
        }
        return Data(bytes)
    }
}
