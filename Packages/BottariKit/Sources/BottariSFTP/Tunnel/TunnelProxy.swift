import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization

/// SOCKS5 and HTTP proxies on 127.0.0.1 whose connections leave from the SSH
/// server, like `ssh -D`. Host names are resolved there too, so internal names
/// work. The HTTP port also serves the PAC file at `/bottari.pac`.
public final class TunnelProxy: Sendable {
    public struct Connection: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let host: String
        public let port: Int
        /// "SOCKS" or "HTTP".
        public let kind: String
        public let opened: Date

        public init(id: UUID, host: String, port: Int, kind: String, opened: Date) {
            self.id = id
            self.host = host
            self.port = port
            self.kind = kind
            self.opened = opened
        }
    }

    public enum Activity: Sendable {
        case opened(Connection)
        case closed(UUID)
        case failed(host: String, port: Int, reason: String)
    }

    public let socksPort: Int
    public let httpPort: Int?
    /// Connections opening and closing, for the "who is using this" list.
    public let activity: AsyncStream<Activity>
    private let listeners: [any Channel]
    private let report: AsyncStream<Activity>.Continuation

    private init(socksPort: Int, httpPort: Int?, listeners: [any Channel], activity: AsyncStream<Activity>, report: AsyncStream<Activity>.Continuation) {
        self.socksPort = socksPort
        self.httpPort = httpPort
        self.listeners = listeners
        self.activity = activity
        self.report = report
    }

    /// Port 0 picks a free one. `pac` is asked for the PAC file on each request.
    static func start(on client: SSHClient, socksPort: Int, httpPort: Int?, pac: @escaping @Sendable () -> String) async throws -> TunnelProxy {
        let (activity, report) = AsyncStream.makeStream(of: Activity.self)
        let opener = DirectChannelOpener(client: client, report: report)
        let socks = try await ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SOCKSHandshake(opener: opener))
                }
            }
            .bind(host: "127.0.0.1", port: socksPort)
            .get()
        var listeners: [any Channel] = [socks]
        var boundHTTP: Int?
        if let httpPort {
            do {
                let http = try await ServerBootstrap(group: client.eventLoop)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(HTTPProxyHandshake(opener: opener, pac: pac))
                        }
                    }
                    .bind(host: "127.0.0.1", port: httpPort)
                    .get()
                listeners.append(http)
                boundHTTP = http.localAddress?.port
            } catch {
                try? await socks.close()
                throw error
            }
        }
        return TunnelProxy(
            socksPort: socks.localAddress?.port ?? socksPort,
            httpPort: boundHTTP,
            listeners: listeners,
            activity: activity,
            report: report
        )
    }

    public func close() async {
        for listener in listeners {
            try? await listener.close()
        }
        report.finish()
    }
}

extension SFTPFileProvider {
    /// Starts SOCKS5 (and optionally HTTP) proxies through this server.
    public func startProxy(socksPort: Int, httpPort: Int?, pac: @escaping @Sendable () -> String) async throws -> TunnelProxy {
        try await TunnelProxy.start(on: connection.client, socksPort: socksPort, httpPort: httpPort, pac: pac)
    }
}

/// Opens direct-tcpip channels for the proxies and wires them to the local side.
private struct DirectChannelOpener: Sendable {
    let client: UncheckedSendable<SSHClient>
    let report: AsyncStream<TunnelProxy.Activity>.Continuation

    init(client: SSHClient, report: AsyncStream<TunnelProxy.Activity>.Continuation) {
        self.client = UncheckedSendable(client)
        self.report = report
    }

    /// Connects `local` to `host:port` at the server. `then` runs on the local
    /// channel's loop with the outcome, before any relayed bytes flow.
    func open(_ host: String, _ port: Int, kind: String, for local: any Channel, then: @escaping @Sendable (Result<any Channel, any Error>) -> Void) {
        let report = report
        let client = client
        Task {
            do {
                let remote = try await client.value.createDirectTCPIPChannel(
                    using: .init(targetHost: host, targetPort: port, originatorAddress: local.remoteAddress ?? (try SocketAddress(ipAddress: "127.0.0.1", port: 0)))
                ) { remote in
                    remote.eventLoop.makeCompletedFuture {
                        try remote.pipeline.syncOperations.addHandler(Relay(to: local))
                    }
                }
                let connection = TunnelProxy.Connection(id: UUID(), host: host, port: port, kind: kind, opened: Date())
                report.yield(.opened(connection))
                local.closeFuture.whenComplete { _ in report.yield(.closed(connection.id)) }
                local.eventLoop.execute { then(.success(remote)) }
            } catch {
                report.yield(.failed(host: host, port: port, reason: error.localizedDescription))
                local.eventLoop.execute { then(.failure(error)) }
            }
        }
    }
}

/// Swaps the handshake handler for a relay to `remote`, passing on bytes the
/// client sent ahead of time.
private func startRelaying<Handshake: RemovableChannelHandler>(_ context: ChannelHandlerContext, to remote: any Channel, handshake: Handshake, leftover: ByteBuffer?) {
    let channel = context.channel
    do {
        try channel.pipeline.syncOperations.addHandler(Relay(to: remote))
        if let leftover, leftover.readableBytes > 0 {
            remote.writeAndFlush(leftover, promise: nil)
        }
        channel.pipeline.syncOperations.removeHandler(handshake, promise: nil)
        channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
        channel.read()
    } catch {
        channel.close(promise: nil)
        remote.close(promise: nil)
    }
}

// MARK: - SOCKS5

private final class SOCKSHandshake: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage { case greeting, request, connecting }

    private let opener: DirectChannelOpener
    private var stage = Stage.greeting
    private var buffer = ByteBuffer()

    init(opener: DirectChannelOpener) {
        self.opener = opener
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        advance(context)
    }

    private func advance(_ context: ChannelHandlerContext) {
        switch stage {
        case .greeting:
            guard buffer.readableBytes >= 2, let bytes = buffer.getBytes(at: buffer.readerIndex, length: 2) else { return }
            guard bytes[0] == 5 else { return fail(context) }
            let count = Int(bytes[1])
            guard buffer.readableBytes >= 2 + count, let methods = buffer.getBytes(at: buffer.readerIndex + 2, length: count) else { return }
            buffer.moveReaderIndex(forwardBy: 2 + count)
            guard methods.contains(0) else {
                // Only "no authentication": the port listens on 127.0.0.1 alone.
                context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [5, 0xFF])), promise: nil)
                return fail(context)
            }
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [5, 0])), promise: nil)
            stage = .request
            advance(context)
        case .request:
            guard let (host, port, length) = parseRequest() else { return }
            buffer.moveReaderIndex(forwardBy: length)
            stage = .connecting
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            let channel = context.channel
            opener.open(host, port, kind: "SOCKS", for: channel) { [self] result in
                // `then` runs on the channel's loop.
                guard let context = try? channel.pipeline.syncOperations.context(handler: self) else { return }
                switch result {
                case .success(let remote):
                    context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])), promise: nil)
                    startRelaying(context, to: remote, handshake: self, leftover: buffer)
                case .failure:
                    // 5: connection refused.
                    context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [5, 5, 0, 1, 0, 0, 0, 0, 0, 0])), promise: nil)
                    fail(context)
                }
            }
        case .connecting:
            break
        }
    }

    /// CONNECT requests only: the target and how many bytes the request took.
    private func parseRequest() -> (String, Int, Int)? {
        guard buffer.readableBytes >= 5, let head = buffer.getBytes(at: buffer.readerIndex, length: 5) else { return nil }
        let start = buffer.readerIndex
        let host: String
        var offset: Int
        switch head[3] {
        case 1:
            guard buffer.readableBytes >= 10, let address = buffer.getBytes(at: start + 4, length: 4) else { return nil }
            host = address.map(String.init).joined(separator: ".")
            offset = 8
        case 3:
            let length = Int(head[4])
            guard buffer.readableBytes >= 5 + length + 2, let name = buffer.getString(at: start + 5, length: length) else { return nil }
            host = name
            offset = 5 + length
        case 4:
            guard buffer.readableBytes >= 22, let address = buffer.getBytes(at: start + 4, length: 16) else { return nil }
            host = IPv6.format(address)
            offset = 20
        default:
            return ("", 0, buffer.readableBytes)
        }
        guard head[1] == 1, let portBytes = buffer.getBytes(at: start + offset, length: 2) else { return ("", 0, offset + 2) }
        return (host, Int(portBytes[0]) << 8 | Int(portBytes[1]), offset + 2)
    }

    private func fail(_ context: ChannelHandlerContext) {
        context.close(promise: nil)
    }
}

// MARK: - HTTP

private final class HTTPProxyHandshake: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let opener: DirectChannelOpener
    private let pac: @Sendable () -> String
    private var buffer = ByteBuffer()
    private var connecting = false

    init(opener: DirectChannelOpener, pac: @escaping @Sendable () -> String) {
        self.opener = opener
        self.pac = pac
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard !connecting else { return }
        let view = buffer.readableBytesView
        guard let end = view.firstRange(of: Array("\r\n\r\n".utf8)) else {
            if buffer.readableBytes > 64 * 1024 { context.close(promise: nil) }
            return
        }
        let headLength = end.upperBound - view.startIndex
        guard let head = buffer.readString(length: headLength) else { return }
        var lines = head.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count == 3 else { return respond(context, status: "400 Bad Request") }
        let (method, target, version) = (requestLine[0], requestLine[1], requestLine[2])

        if method == "CONNECT" {
            let parts = target.split(separator: ":")
            guard parts.count >= 2, let port = Int(parts.last!) else { return respond(context, status: "400 Bad Request") }
            let host = parts.dropLast().joined(separator: ":").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            connect(context, host: host, port: port, greeting: ByteBuffer(string: "\(version) 200 Connection Established\r\n\r\n"), forward: nil)
        } else if let url = URL(string: target), url.scheme?.lowercased() == "http", let host = url.host() {
            // Plain HTTP: send the request on with an origin-form target.
            var path = url.path(percentEncoded: true)
            if path.isEmpty { path = "/" }
            if let query = url.query(percentEncoded: true) { path += "?" + query }
            let headers = lines.filter { line in
                let name = line.split(separator: ":").first?.lowercased() ?? ""
                return name != "proxy-connection" && name != "proxy-authorization" && name != "connection"
            }
            let rewritten = ([ "\(method) \(path) \(version)" ] + headers + ["Connection: close", "", ""]).joined(separator: "\r\n")
            connect(context, host: host, port: url.port ?? 80, greeting: nil, forward: ByteBuffer(string: rewritten))
        } else if method == "GET", target.hasSuffix(".pac") {
            respond(context, status: "200 OK", type: "application/x-ns-proxy-autoconfig", body: pac())
        } else {
            respond(context, status: "400 Bad Request")
        }
    }

    private func connect(_ context: ChannelHandlerContext, host: String, port: Int, greeting: ByteBuffer?, forward: ByteBuffer?) {
        connecting = true
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        let channel = context.channel
        opener.open(host, port, kind: "HTTP", for: channel) { [self] result in
            guard let context = try? channel.pipeline.syncOperations.context(handler: self) else { return }
            switch result {
            case .success(let remote):
                if let greeting {
                    context.writeAndFlush(wrapOutboundOut(greeting), promise: nil)
                }
                if let forward {
                    remote.writeAndFlush(forward, promise: nil)
                }
                startRelaying(context, to: remote, handshake: self, leftover: buffer)
            case .failure:
                respond(context, status: "502 Bad Gateway")
            }
        }
    }

    private func respond(_ context: ChannelHandlerContext, status: String, type: String = "text/plain", body: String = "") {
        let text = body.isEmpty ? status + "\n" : body
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n\(text)"
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: response))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
