import _CryptoExtras
import BottariCore
import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// The agent a server may use while a command runs there with agent
/// forwarding: keys Bottari read from files, signing with them itself. The
/// private keys never leave the Mac; the server can only ask for signatures,
/// and only while the command runs.
struct ForwardedAgent: Sendable {
    let keys: [PrivateKeyFile]

    static func keys(_ keys: [PrivateKeyFile]) -> ForwardedAgent {
        ForwardedAgent(keys: keys)
    }

    /// Starts serving one agent channel the server opened.
    func attach(to channel: any Channel) -> EventLoopFuture<Void> {
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandlers(SSHChannelDataCodec(), InProcessAgent(keys: keys))
        }
    }
}

/// Turns an SSH channel's data messages into plain bytes and back, so byte
/// handlers such as `InProcessAgent` work on it.
final class SSHChannelDataCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(let bytes) = message.data else { return }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

/// Answers the SSH agent protocol from keys in memory: lists them and signs
/// with them. Anything else is refused, which `ssh` takes in its stride.
final class InProcessAgent: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let keys: [(blob: Data, key: PrivateKeyFile)]
    private var pending = ByteBuffer()

    init(keys: [PrivateKeyFile]) {
        self.keys = keys.map { ($0.publicKeyBlob, $0) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        pending.writeBuffer(&bytes)
        while let length = pending.getInteger(at: pending.readerIndex, as: UInt32.self),
              pending.readableBytes >= 4 + Int(length) {
            pending.moveReaderIndex(forwardBy: 4)
            let request = Data(pending.readBytes(length: Int(length)) ?? [])
            var reply = Data()
            let answer = Self.answer(request, keys: keys)
            reply.appendUInt32(UInt32(answer.count))
            reply.append(answer)
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: reply)), promise: nil)
        }
        pending.discardReadBytes()
    }

    private enum Message {
        static let failure: UInt8 = 5
        static let requestIdentities: UInt8 = 11
        static let identitiesAnswer: UInt8 = 12
        static let signRequest: UInt8 = 13
        static let signResponse: UInt8 = 14
    }

    static func answer(_ request: Data, keys: [(blob: Data, key: PrivateKeyFile)]) -> Data {
        var wire = SSHWire(request)
        guard let type = try? wire.readByte() else { return Data([Message.failure]) }
        switch type {
        case Message.requestIdentities:
            var reply = Data([Message.identitiesAnswer])
            reply.appendUInt32(UInt32(keys.count))
            for (blob, _) in keys {
                reply.appendSSHString(blob)
                reply.appendSSHString(Data("Bottari".utf8))
            }
            return reply
        case Message.signRequest:
            guard let blob = try? wire.readString(), let data = try? wire.readString(), let flags = try? wire.readUInt32(),
                  let key = keys.first(where: { $0.blob == blob })?.key,
                  let (name, signature) = try? key.agentSignature(for: data, flags: flags)
            else { return Data([Message.failure]) }
            var inner = Data()
            inner.appendSSHString(Data(name.utf8))
            inner.appendSSHString(signature)
            var reply = Data([Message.signResponse])
            reply.appendSSHString(inner)
            return reply
        default:
            return Data([Message.failure])
        }
    }
}

extension PrivateKeyFile {
    /// A signature as an agent hands it out: the algorithm name and the blob
    /// after it. For RSA, `flags` picks SHA-512 (4), SHA-256 (2) or SHA-1.
    func agentSignature(for data: Data, flags: UInt32) throws -> (name: String, blob: Data) {
        func ecdsa(_ raw: Data) -> Data {
            var blob = Data()
            blob.appendSSHString(raw.prefix(raw.count / 2).asMPInt)
            blob.appendSSHString(raw.suffix(raw.count / 2).asMPInt)
            return blob
        }
        switch self {
        case .ed25519(let key):
            return (Ed25519Kind.name, try key.signature(for: data))
        case .p256(let key):
            return (ECDSAP256Kind.name, ecdsa(try key.signature(for: data).rawRepresentation))
        case .p384(let key):
            return (ECDSAP384Kind.name, ecdsa(try key.signature(for: data).rawRepresentation))
        case .p521(let key):
            return (ECDSAP521Kind.name, ecdsa(try key.signature(for: data).rawRepresentation))
        case .rsa(let key, _):
            if flags & 4 != 0 {
                return ("rsa-sha2-512", try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation)
            }
            if flags & 2 != 0 {
                return ("rsa-sha2-256", try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation)
            }
            return (RSASHA1Kind.name, try key.signature(for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation)
        }
    }
}

/// What a command printed and how it ended.
struct CommandResult: Sendable {
    var output: String
    var errors: String
    /// Nil if the server did not say, e.g. the command was killed by a signal.
    var exitStatus: Int?
}

extension SFTPConnection {
    /// Runs `command` in a session that may use `agent` while it runs, as
    /// `ssh -A` would.
    func run(_ command: String, forwarding agent: ForwardedAgent) async throws -> CommandResult {
        let handler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let collector = CommandCollector()
        let session: any Channel = try await channel.eventLoop.flatSubmit { [channel] in
            handler.setAgentForwardingInitializer { agent.attach(to: $0) }
            let opened = channel.eventLoop.makePromise(of: (any Channel).self)
            handler.createChannel(opened, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(collector)
                }
            }
            return opened.futureResult
        }.get()
        try await session.triggerUserOutboundEvent(SSHChannelRequestEvent.AgentForwardingRequest(wantReply: false)).get()
        try await session.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)).get()
        return try await withTaskCancellationHandler {
            try await collector.result.get()
        } onCancel: {
            session.close(promise: nil)
        }
    }
}

/// Gathers a command's output and exit status until its channel closes.
private final class CommandCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private var output = ByteBuffer()
    private var errors = ByteBuffer()
    private var exitStatus: Int?
    private var promise: EventLoopPromise<CommandResult>?
    private let resultBox = ResultBox()

    var result: EventLoopFuture<CommandResult> {
        resultBox.future
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let promise = context.eventLoop.makePromise(of: CommandResult.self)
        self.promise = promise
        resultBox.set(promise.futureResult)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = message.data else { return }
        switch message.type {
        case .channel: output.writeBuffer(&bytes)
        case .stdErr: errors.writeBuffer(&bytes)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = status.exitStatus
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise?.succeed(CommandResult(output: String(buffer: output), errors: String(buffer: errors), exitStatus: exitStatus))
        promise = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise?.fail(error)
        promise = nil
        context.close(promise: nil)
    }

    /// The result future, readable from any thread once the handler is in place.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: EventLoopFuture<CommandResult>?

        func set(_ future: EventLoopFuture<CommandResult>) {
            lock.withLock { stored = future }
        }

        var future: EventLoopFuture<CommandResult> {
            lock.withLock { stored! }
        }
    }
}
