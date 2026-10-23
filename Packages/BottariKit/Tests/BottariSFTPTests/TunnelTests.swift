import BottariCore
import Foundation
import JavaScriptCore
import NIOCore
import NIOPosix
import Testing
@testable import BottariSFTP

@Suite struct RouteRulesTests {
    let rules = RouteRules.parse("""
    10.0.0.0/8
    192.168.1.5
    *.corp.example
    gitlab.internal
    fd00::/8
    # a comment
    nonsense/xx, 300.1.1.1
    """)

    @Test func parsesRulesAndReportsTheRest() {
        #expect(rules.rules.rules.count == 5)
        #expect(rules.invalid == ["nonsense/xx", "300.1.1.1"])
    }

    @Test(arguments: [
        ("10.20.30.40", true), ("11.0.0.1", false), ("192.168.1.5", true), ("192.168.1.6", false),
        ("build.corp.example", true), ("corp.example", true), ("evilcorp.example", false),
        ("gitlab.internal", true), ("GITLAB.internal", true), ("github.com", false),
        ("fd12::1", true), ("2001:db8::1", false),
    ])
    func matchesAddresses(host: String, expected: Bool) {
        #expect(rules.rules.matches(host) == expected)
    }

    @Test func everythingMeansEverything() {
        #expect(RouteRules.parse("0/0").rules.matches("example.com"))
        #expect(RouteRules.parse("0/0").rules.subnets == ["0/0"])
    }

    @Test func sshuttleGetsRangesAndHosts() {
        #expect(rules.rules.subnets == ["10.0.0.0/8", "192.168.1.5/32", "gitlab.internal", "fd00::/8"])
    }

    /// Runs the PAC file the way browsers do, with the standard helper functions.
    @Test func pacSendsOnlyMatchingHostsThroughTheTunnel() throws {
        let pac = rules.rules.pacFile(socksPort: 1080, httpPort: 8118, fallBackToDirect: false)
        let context = try #require(JSContext())
        context.evaluateScript("""
        function dnsDomainIs(host, domain) { return host.length >= domain.length && host.substring(host.length - domain.length) == domain; }
        function isInNet(ip, net, mask) {
          function n(a) { var p = a.split('.'); return ((+p[0] << 24) >>> 0) + (+p[1] << 16) + (+p[2] << 8) + (+p[3]); }
          return ((n(ip) & n(mask)) >>> 0) == ((n(net) & n(mask)) >>> 0);
        }
        """)
        context.evaluateScript(pac)
        func proxy(_ host: String) -> String? {
            context.objectForKeyedSubscript("FindProxyForURL")?.call(withArguments: ["http://\(host)/", host])?.toString()
        }
        let tunnel = "SOCKS5 127.0.0.1:1080; SOCKS 127.0.0.1:1080; PROXY 127.0.0.1:8118"
        #expect(proxy("10.1.2.3") == tunnel)
        #expect(proxy("app.corp.example") == tunnel)
        #expect(proxy("gitlab.internal") == tunnel)
        #expect(proxy("github.com") == "DIRECT")
        #expect(proxy("11.1.2.3") == "DIRECT")
    }
}

/// Sends back whatever arrives.
private final class Echo: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

/// Collects bytes until `expected` have arrived.
final class Gather: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    var expected = Int.max
    var done: EventLoopPromise<[UInt8]>?
    var received: [UInt8] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received += unwrapInboundIn(data).readableBytesView
        if received.count >= expected, let done {
            self.done = nil
            done.succeed(Array(received.prefix(expected)))
            received.removeFirst(expected)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        done?.succeed(received)
        done = nil
    }
}

@Suite(.timeLimit(.minutes(1))) struct TunnelProxyTests {
    let group = MultiThreadedEventLoopGroup.singleton

    /// A client connection that can wait for the next `count` bytes.
    final class Client: @unchecked Sendable {
        let channel: any Channel
        let gather: Gather

        init(channel: any Channel, gather: Gather) {
            self.channel = channel
            self.gather = gather
        }

        func exchange(_ bytes: [UInt8], expecting count: Int) async throws -> [UInt8] {
            let done = channel.eventLoop.makePromise(of: [UInt8].self)
            try await channel.eventLoop.submit {
                self.gather.expected = count
                self.gather.done = done
            }.get()
            if !bytes.isEmpty {
                try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
            }
            return try await done.futureResult.get()
        }
    }

    func client(port: Int) async throws -> Client {
        let gather = Gather()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(gather) }
            .connect(host: "127.0.0.1", port: port).get()
        return Client(channel: channel, gather: gather)
    }

    func withProxy(_ body: (TunnelProxy, Int) async throws -> Void) async throws {
        let echo = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(Echo()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let server = try await TestSFTPServer.start(forwarding: true)
        let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .password(TestSFTPServer.password), hostKeys: .acceptAnything)
        let proxy = try await provider.startProxy(socksPort: 0, httpPort: 0) { "function FindProxyForURL(u, h) { return \"DIRECT\"; }" }
        do {
            try await body(proxy, echo.localAddress!.port!)
        } catch {
            await proxy.close()
            await provider.disconnect()
            await server.stop()
            throw error
        }
        await proxy.close()
        await provider.disconnect()
        await server.stop()
        try? await echo.close()
    }

    @Test func socks5ConnectsByNameThroughTheServer() async throws {
        try await withProxy { proxy, echoPort in
            let client = try await client(port: proxy.socksPort)
            #expect(try await client.exchange([5, 1, 0], expecting: 2) == [5, 0])
            let name = Array("localhost".utf8)
            let request = [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(echoPort >> 8), UInt8(echoPort & 0xFF)]
            #expect(try await client.exchange(request, expecting: 10).prefix(2) == [5, 0])
            #expect(try await client.exchange(Array("ping".utf8), expecting: 4) == Array("ping".utf8))
            try? await client.channel.close()
        }
    }

    @Test func socks5RefusesWhenTheTargetIsClosed() async throws {
        try await withProxy { proxy, _ in
            let client = try await client(port: proxy.socksPort)
            _ = try await client.exchange([5, 1, 0], expecting: 2)
            let reply = try await client.exchange([5, 1, 0, 1, 127, 0, 0, 1, 0, 1], expecting: 10)
            #expect(reply.prefix(2) == [5, 5])
        }
    }

    @Test func httpConnectAndThePacFile() async throws {
        try await withProxy { proxy, echoPort in
            let http = try #require(proxy.httpPort)
            let tunnel = try await client(port: http)
            let greeting = "HTTP/1.1 200 Connection Established\r\n\r\n"
            let reply = try await tunnel.exchange(Array("CONNECT 127.0.0.1:\(echoPort) HTTP/1.1\r\nHost: x\r\n\r\n".utf8), expecting: greeting.utf8.count)
            #expect(String(decoding: reply, as: UTF8.self) == greeting)
            #expect(try await tunnel.exchange(Array("hello".utf8), expecting: 5) == Array("hello".utf8))
            try? await tunnel.channel.close()

            let pac = try await client(port: http)
            let body = try await pac.exchange(Array("GET /bottari.pac HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), expecting: .max)
            let text = String(decoding: body, as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 200 OK"))
            #expect(text.contains("application/x-ns-proxy-autoconfig"))
            #expect(text.contains("FindProxyForURL"))
        }
    }
}
