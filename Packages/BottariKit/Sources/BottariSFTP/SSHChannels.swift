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

    /// A size a pseudo-terminal can have: SSH sends it unsigned, and Citadel
    /// stops the app on a negative one.
    static func clamped(_ value: Int) -> Int {
        min(max(value, 1), 10_000)
    }

    /// `locate` finds where `folder`, as SFTP shows it, is for the shell;
    /// nil if it cannot tell (the server runs no commands) or found nothing.
    init(link: SFTPLink, columns: Int, rows: Int, folder: RemotePath?, canLocate: Bool, locate: @escaping @Sendable (RemotePath) async -> String?) {
        let (events, output) = AsyncStream.makeStream(of: Event.self)
        let (inputs, input) = AsyncStream.makeStream(of: Input.self)
        self.events = events
        self.input = input
        task = Task {
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: Self.clamped(columns),
                terminalRowHeight: Self.clamped(rows),
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            do {
                // Where the shell should start: the folder's path for the shell,
                // which on a NAS is not the one SFTP shows.
                var start: String?
                if let folder {
                    if let found = await locate(folder) {
                        start = found
                    } else if canLocate {
                        output.yield(.output(Data((String(localized: "Bottari: \(folder.string) 폴더를 셸에서 찾지 못해 홈 폴더에서 시작합니다.") + "\r\n").utf8)))
                    } else {
                        start = folder.string
                    }
                }
                // Citadel's client and PTY handles are not marked Sendable; they only
                // send through NIO channels, which are.
                let client = UncheckedSendable(try await link.live().client)
                try await client.value.withPTY(request) { inbound, outbound in
                    let inbound = UncheckedSendable(inbound)
                    let outbound = UncheckedSendable(outbound)
                    if let start {
                        try await outbound.value.write(ByteBuffer(string: "cd -- \(SFTPFileProvider.quote(start)) && clear\n"))
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
            } catch ChannelError.alreadyClosed {
                // The server closed the channel when the shell exited; Citadel then
                // tries to close it again.
                output.yield(.closed(nil))
            } catch {
                output.yield(.closed(error.localizedDescription))
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
        input.yield(.resize(columns: Self.clamped(columns), rows: Self.clamped(rows)))
    }

    public func close() {
        input.finish()
        task.cancel()
    }
}

extension SFTPFileProvider {
    /// A shell on the server, starting in `folder`.
    public func openTerminal(columns: Int, rows: Int, in folder: RemotePath? = nil) -> TerminalSession {
        TerminalSession(link: link, columns: columns, rows: rows, folder: folder, canLocate: canRunCommands) { [self] in
            await shellPath(for: $0)
        }
    }

    /// Where `path`, as SFTP shows it, is for a shell on the server. The two
    /// differ where SFTP is confined: Synology and QNAP show their shared
    /// folders at the root over SFTP (`/dcloud`), while the shell sees the
    /// disk (`/volume1/dcloud`, `/share/dcloud`). Nil when the server runs no
    /// commands, or no folder of that name turns up.
    public func shellPath(for path: RemotePath) async -> String? {
        guard canRunCommands, let output = try? await run(Self.shellPathScript(for: path)) else { return nil }
        let found = output.trimmingCharacters(in: .newlines)
        return found.isEmpty ? nil : found
    }

    /// Where shared folders live on NAS systems whose SFTP shows them at the root.
    static let shellPathBases = ["/volume[0-9]*", "/volumeUSB[0-9]*/usbshare*", "/share", "/share/CACHEDEV*_DATA", "/share/MD0_DATA"]

    /// Prints the first of `path` and `path` under each base that is a folder.
    /// The bases are globs left for the shell to expand; the path is quoted.
    static func shellPathScript(for path: RemotePath, bases: [String] = shellPathBases) -> String {
        let quoted = quote(path.string)
        let candidates = ([quoted] + bases.map { $0 + quoted }).joined(separator: " ")
        return "for d in \(candidates); do if [ -d \"$d\" ]; then printf '%s\\n' \"$d\"; exit 0; fi; done; exit 0"
    }

    /// What the server says when asked to connect to `host:port` as it sees
    /// it, e.g. its own VNC port at localhost.
    public enum PortCheck: Sendable, Equatable {
        case answering
        /// Nothing listens there, or no answer came within five seconds.
        case silent
        /// The server does not forward connections at all (AllowTcpForwarding no).
        case forwardingDisabled
    }

    public func checkPort(host: String, port: Int) async -> PortCheck {
        guard (1...65535).contains(port), let client = try? await link.live().client else { return .silent }
        let box = UncheckedSendable(client)
        return await withTaskGroup(of: PortCheck.self) { group in
            group.addTask {
                do {
                    let channel = try await box.value.createDirectTCPIPChannel(
                        using: .init(targetHost: host, targetPort: port, originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
                    ) { $0.eventLoop.makeSucceededVoidFuture() }
                    try? await channel.close()
                    return .answering
                } catch {
                    return Self.isForwardingDisabled(error) ? .forwardingDisabled : .silent
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return .silent
            }
            let answer = await group.next() ?? .silent
            group.cancelAll()
            return answer
        }
    }

    /// A refused channel carries the server's reason; 1 is "administratively
    /// prohibited", where 2 would be a failed connect.
    static func isForwardingDisabled(_ error: any Error) -> Bool {
        guard let error = error as? NIOSSHError, error.type == .channelSetupRejected else { return false }
        return String(describing: error).contains("Reason: 1 ")
    }

    /// Listens on a free port of 127.0.0.1 and carries each connection through
    /// SSH to `host:port` as the server sees it, like `ssh -L`.
    public func forward(toHost host: String, port: Int) async throws -> PortForward {
        try await PortForward.open(on: link.live().client, host: host, port: port)
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
        let listener = try await ServerBootstrap(group: TunnelProxy.listenerLoop)
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
            throw ProviderError.io(String(localized: "터널 포트를 열 수 없습니다"))
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
