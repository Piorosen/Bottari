import BottariCore
import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - Terminal

/// An interactive shell on the server in a pseudo-terminal, over the
/// connection the provider already has.
public final class TerminalSession: Sendable {
    public enum Event: Sendable {
        case output(Data)
        /// The shell ended (nil) or the connection failed (the reason).
        case closed(String?)
    }

    private enum Input: Sendable {
        case bytes(Data)
        case resize(columns: Int, rows: Int)
    }

    /// What the shell prints, then `.closed`.
    public let events: AsyncStream<Event>
    private let input: AsyncStream<Input>.Continuation
    private let task: Task<Void, Never>

    init(client: SSHClient, columns: Int, rows: Int, folder: RemotePath?) {
        let (events, output) = AsyncStream.makeStream(of: Event.self)
        let (inputs, input) = AsyncStream.makeStream(of: Input.self)
        self.events = events
        self.input = input
        // Citadel's client and PTY handles are not marked Sendable; they only send
        // through NIO channels, which are.
        let client = UncheckedSendable(client)
        task = Task {
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: columns,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            do {
                try await client.value.withPTY(request) { inbound, outbound in
                    let inbound = UncheckedSendable(inbound)
                    let outbound = UncheckedSendable(outbound)
                    if let folder {
                        try await outbound.value.write(ByteBuffer(string: "cd -- \(SFTPFileProvider.quote(folder.string)) && clear\n"))
                    }
                    // Keystrokes and size changes go out one by one, in order.
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await chunk in inbound.value {
                                switch chunk {
                                case .stdout(let buffer), .stderr(let buffer):
                                    output.yield(.output(Data(buffer.readableBytesView)))
                                }
                            }
                        }
                        group.addTask {
                            for await item in inputs {
                                switch item {
                                case .bytes(let data):
                                    try await outbound.value.write(ByteBuffer(bytes: data))
                                case .resize(let columns, let rows):
                                    try await outbound.value.changeSize(cols: columns, rows: rows, pixelWidth: 0, pixelHeight: 0)
                                }
                            }
                        }
                        // The shell exiting ends the output; stop sending then.
                        try await group.next()
                        group.cancelAll()
                    }
                }
                output.yield(.closed(nil))
            } catch {
                output.yield(.closed(SFTPConnectError.wrap(error).localizedDescription))
            }
            output.finish()
        }
    }

    public func send(_ data: Data) {
        input.yield(.bytes(data))
    }

    public func send(_ text: String) {
        send(Data(text.utf8))
    }

    public func resize(columns: Int, rows: Int) {
        input.yield(.resize(columns: columns, rows: rows))
    }

    public func close() {
        input.finish()
        task.cancel()
    }
}

extension SFTPFileProvider {
    /// A shell on the server, starting in `folder`.
    public func openTerminal(columns: Int, rows: Int, in folder: RemotePath? = nil) -> TerminalSession {
        TerminalSession(client: connection.client, columns: columns, rows: rows, folder: folder)
    }

    /// Listens on a free port of 127.0.0.1 and carries each connection through
    /// SSH to `host:port` as the server sees it, like `ssh -L`.
    public func forward(toHost host: String, port: Int) async throws -> PortForward {
        try await PortForward.open(on: connection.client, host: host, port: port)
    }
}

// MARK: - Port forwarding

/// A local port whose connections come out at the server, e.g. a VNC server
/// that only listens there. Nothing outside this Mac can reach the port.
public final class PortForward: Sendable {
    public let localPort: Int
    private let listener: any Channel

    private init(localPort: Int, listener: any Channel) {
        self.localPort = localPort
        self.listener = listener
    }

    static func open(on client: SSHClient, host: String, port: Int) async throws -> PortForward {
        let clientBox = UncheckedSendable(client)
        let listener = try await ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Hold incoming bytes until the SSH side is open.
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { local in
                let ready = local.eventLoop.makePromise(of: Void.self)
                ready.completeWithTask {
                    let remote = try await clientBox.value.createDirectTCPIPChannel(
                        using: .init(targetHost: host, targetPort: port, originatorAddress: local.remoteAddress ?? (try SocketAddress(ipAddress: "127.0.0.1", port: 0)))
                    ) { remote in
                        remote.eventLoop.makeCompletedFuture {
                            try remote.pipeline.syncOperations.addHandler(Relay(to: local))
                        }
                    }
                    try await local.pipeline.addHandler(Relay(to: remote))
                    try await local.setOption(ChannelOptions.autoRead, value: true).get()
                }
                return ready.futureResult.flatMapErrorThrowing { error in
                    local.close(promise: nil)
                    throw error
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let localPort = listener.localAddress?.port else {
            try? await listener.close()
            throw ProviderError.io("터널 포트를 열지 못했어요")
        }
        return PortForward(localPort: localPort, listener: listener)
    }

    public func close() async {
        try? await listener.close()
    }
}

/// Copies bytes to the other side of a forwarded connection. Reading pauses
/// while the other side cannot keep up, and a close on one side closes both.
final class Relay: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let partner: any Channel

    init(to partner: any Channel) {
        self.partner = partner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        partner.writeAndFlush(bytes, promise: nil)
        if !partner.isWritable {
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            let own = context.channel
            partner.eventLoop.execute { [partner] in
                Self.resume(own, whenWritable: partner)
            }
        }
    }

    private static func resume(_ channel: any Channel, whenWritable partner: any Channel) {
        if partner.isWritable || !partner.isActive {
            channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
        } else {
            partner.eventLoop.scheduleTask(in: .milliseconds(5)) {
                resume(channel, whenWritable: partner)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner.close(promise: nil)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // The other end finished sending: pass the half-close on.
        if event is ChannelEvent, case .inputClosed = event as! ChannelEvent {
            partner.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
