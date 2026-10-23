import BottariCore
import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import BottariSFTP

/// Sends back whatever arrives.
private final class Echo: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

/// Completes once `expected` bytes have arrived.
private final class Collect: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let expected: Int
    let done: EventLoopPromise<Data>
    var received = Data()

    init(expected: Int, done: EventLoopPromise<Data>) {
        self.expected = expected
        self.done = done
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        if received.count >= expected { done.succeed(received) }
    }
}

@Suite(.timeLimit(.minutes(1))) struct PortForwardTests {
    @Test func carriesBytesBothWaysThroughTheServer() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let echo = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(Echo()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let server = try await TestSFTPServer.start(forwarding: true)
        let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .password(TestSFTPServer.password), hostKeys: .acceptAnything)

        let forward = try await provider.forward(toHost: "127.0.0.1", port: echo.localAddress!.port!)
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        let done = group.next().makePromise(of: Data.self)
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(Collect(expected: payload.count, done: done)) }
            .connect(host: "127.0.0.1", port: forward.localPort).get()
        try await client.writeAndFlush(ByteBuffer(bytes: payload)).get()
        let echoed = try await done.futureResult.get()

        #expect(echoed == payload)
        try? await client.close()
        await forward.close()
        await provider.disconnect()
        await server.stop()
        try? await echo.close()
    }
}
