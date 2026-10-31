import BottariCore
import Citadel
import Foundation
import NIOCore
import Synchronization
import Testing
@testable import BottariSFTP

@Suite(.timeLimit(.minutes(1))) struct SFTPFileProviderTests {
    /// Starts a server, runs `body`, and stops the server even if `body` throws.
    func withServer(port: Int? = nil, _ body: (TestSFTPServer) async throws -> Void) async throws {
        let server = try await TestSFTPServer.start(port: port)
        do {
            try await body(server)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    /// Like `withServer`, plus a connection made with the password.
    func withConnection(_ body: (TestSFTPServer, SFTPFileProvider) async throws -> Void) async throws {
        try await withServer { server in
            let provider = try await SFTPFileProvider.connect(
                to: server.endpoint,
                credential: .password(TestSFTPServer.password),
                hostKeys: .acceptAnything
            )
            do {
                try await body(server, provider)
            } catch {
                await provider.disconnect()
                throw error
            }
            await provider.disconnect()
        }
    }

    // MARK: Connecting

    @Test func connectsWithPasswordAndStartsAtHome() async throws {
        try await withConnection { server, provider in
            #expect(provider.home == .root)
            #expect(provider.displayName == "127.0.0.1")
            #expect(provider.endpoint == server.endpoint)
        }
    }

    @Test func connectsWithEd25519PrivateKey() async throws {
        try await withServer { server in
            let provider = try await SFTPFileProvider.connect(
                to: server.endpoint,
                credential: .privateKey(server.clientKey.makeSSHRepresentation()),
                hostKeys: .acceptAnything
            )
            try server.makeFile("/hello.txt", "hi")
            #expect(try await provider.list(.root).map(\.name) == ["hello.txt"])
            await provider.disconnect()
        }
    }

    @Test func wrongPasswordFailsAuthentication() async throws {
        try await withServer { server in
            await #expect(throws: SFTPConnectError.authenticationFailed) {
                _ = try await SFTPFileProvider.connect(
                    to: server.endpoint,
                    credential: .password("wrong"),
                    hostKeys: .acceptAnything
                )
            }
        }
    }

    @Test func aClosedPortIsReportedAsRefused() async throws {
        let server = try await TestSFTPServer.start()
        let endpoint = server.endpoint
        await server.stop()
        await #expect(throws: SFTPConnectError.refused(address: "127.0.0.1:\(endpoint.port)")) {
            _ = try await SFTPFileProvider.connect(
                to: endpoint,
                credential: .password(TestSFTPServer.password),
                hostKeys: .acceptAnything
            )
        }
    }

    @Test func networkFailuresNameTheAddress() {
        let server = SFTPEndpoint(host: "203.0.113.10", port: 30084, username: "ubuntu")
        #expect(SFTPConnectError.networkFailure(ChannelError.connectTimeout(.seconds(15)), dialling: server)
            == .noResponse(address: "203.0.113.10:30084", seconds: 15))
        #expect(SFTPConnectError.networkFailure(IOError(errnoCode: ENETUNREACH, reason: "connect"), dialling: SFTPEndpoint(host: "nas.local", username: "me"))
            == .noRoute(address: "nas.local"))
        #expect(SFTPConnectError.networkFailure(SFTPConnectError.authenticationFailed, dialling: server) == nil)
        #expect(SFTPConnectError.noResponse(address: "203.0.113.10:30084", seconds: 15).localizedDescription
            .hasPrefix("203.0.113.10:30084에서 15초 동안 응답이 없습니다."))
    }

    @Test func garbageKeyTextIsReportedAsUnreadable() {
        #expect(throws: SFTPConnectError.unreadableKey) {
            _ = try SFTPCredential.privateKey("not a key").authenticationAttempts(username: "me")
        }
    }

    @Test func trustOnFirstUseRemembersKeyAndRejectsAChangedOne() async throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("known-hosts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let knownHosts = KnownHosts(fileURL: storeURL)

        let first = try await TestSFTPServer.start()
        let provider = try await SFTPFileProvider.connect(
            to: first.endpoint,
            credential: .password(TestSFTPServer.password),
            hostKeys: .knownHosts(knownHosts)
        )
        await provider.disconnect()
        await first.stop()
        let remembered = try #require(knownHosts.trustedKey(for: first.endpoint))
        #expect(KnownHosts(fileURL: storeURL).trustedKey(for: first.endpoint) == remembered)
        #expect(knownHosts.remembered.map(\.key) == [remembered])

        // Same address, new host key: what a man-in-the-middle would look like.
        try await withServer(port: first.port) { impostor in
            await #expect {
                _ = try await SFTPFileProvider.connect(
                    to: impostor.endpoint,
                    credential: .password(TestSFTPServer.password),
                    hostKeys: .knownHosts(knownHosts)
                )
            } throws: { error in
                guard case SFTPConnectError.hostKeyChanged(let host, let expected, _) = error else { return false }
                return host == impostor.endpoint.hostKeyID && expected == KnownHosts.fingerprint(ofOpenSSHKey: remembered)
            }
        }
        #expect(knownHosts.trustedKey(for: first.endpoint) == remembered)
    }

    // MARK: Dropped connections

    @Test func aDroppedConnectionIsOpenedAgainOnTheNextRequest() async throws {
        try await withConnection { server, provider in
            try server.makeFile("/notes.txt", "hello")
            let identity = provider.connectionID
            let dropped = Counter()
            provider.whenDisconnected { dropped.add() }

            try await provider.link.current.client.close()
            #expect(!provider.isConnected)
            #expect(try await provider.list("/").map(\.name) == ["notes.txt"])
            #expect(provider.isConnected)
            #expect(provider.connectionID == identity)
            #expect(String(decoding: try await provider.readData("/notes.txt"), as: UTF8.self) == "hello")
            // Disconnect handlers run on a task of their own.
            for _ in 0..<50 where dropped.value == 0 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(dropped.value == 1)
        }
    }

    @Test func requestsAfterADropShareOneReconnection() async throws {
        try await withConnection { server, provider in
            try server.makeDirectory("/a")
            let before = provider.link.current
            try await before.client.close()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<5 {
                    group.addTask { _ = try await provider.stat("/a") }
                }
                try await group.waitForAll()
            }
            let after = provider.link.current
            #expect(after !== before)
            #expect(after.client.isConnected)
        }
    }

    @Test func aDisconnectedProviderStaysClosed() async throws {
        try await withConnection { _, provider in
            await provider.disconnect()
            await #expect(throws: ProviderError.self) { _ = try await provider.list("/") }
            #expect(!provider.isConnected)
        }
    }

    @Test func aQuietConnectionThatStillAnswersIsKept() async throws {
        try await withConnection { _, provider in
            let connection = provider.link.current
            #expect(await connection.ping(within: .seconds(5)))
            #expect(connection.heartbeat.quiet < .seconds(5))
        }
    }

    // MARK: Browsing

    @Test func listsInFinderOrderWithAttributes() async throws {
        try await withConnection { server, provider in
            try server.makeDirectory("/releases")
            try server.makeFile("/file10.txt", "ten")
            try server.makeFile("/File2.txt", "two!", mode: 0o640)
            try FileManager.default.createSymbolicLink(
                atPath: server.url("/latest").path,
                withDestinationPath: server.url("/releases").path
            )

            let items = try await provider.list(.root)

            #expect(items.map(\.name) == ["latest", "releases", "File2.txt", "file10.txt"])
            let latest = try #require(items.first)
            #expect(latest.isDirectory && latest.isSymbolicLink)
            let two = items[2]
            #expect(two.size == 4)
            #expect(two.permissionString == "-rw-r-----")
            #expect(two.owner == TestSFTPServer.username)
            #expect(two.modified != nil)
            #expect(items[1].size == nil)
        }
    }

    @Test func statFollowsTheGivenPath() async throws {
        try await withConnection { server, provider in
            try server.makeDirectory("/var/www")
            try server.makeFile("/var/www/index.html", "<html></html>")

            let file = try await provider.stat("/var/www/index.html")
            #expect(file.kind == .file)
            #expect(file.size == 13)
            #expect(try await provider.stat("/var/www").isDirectory)
        }
    }

    // MARK: Reading and writing

    @Test func readsWholeFilesAndRanges() async throws {
        try await withConnection { server, provider in
            try server.makeFile("/digits.txt", "0123456789")

            #expect(try await provider.readData("/digits.txt") == Data("0123456789".utf8))
            #expect(try await provider.readData("/digits.txt", range: 2..<5) == Data("234".utf8))
            #expect(try await provider.readData("/digits.txt", range: 8..<100) == Data("89".utf8))
        }
    }

    @Test func readsLargeFilesInSeveralRequests() async throws {
        try await withConnection { server, provider in
            let payload = Data((0..<(Int(SFTPFileProvider.chunkSize) * 2 + 5)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            try payload.write(to: server.url("/big.bin"))

            var chunks = 0
            var received = Data()
            for try await chunk in provider.read("/big.bin", range: nil) {
                chunks += 1
                received.append(chunk)
            }
            #expect(chunks == 3)
            #expect(received == payload)
        }
    }

    @Test func pipelinedTransfersKeepEveryByteInOrder() async throws {
        try await withConnection { server, provider in
            // Several read and write windows' worth, not a multiple of any chunk size.
            let payload = Data((0..<(5 * 1024 * 1024 + 12_345)).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 9)) })
            let upload = AsyncThrowingStream<Data, any Error> { continuation in
                var offset = 0
                while offset < payload.count {
                    let length = min(70_001, payload.count - offset)
                    continuation.yield(payload.subdata(in: offset..<offset + length))
                    offset += length
                }
                continuation.finish()
            }

            try await provider.write("/video.bin", from: upload)

            #expect(try Data(contentsOf: server.url("/video.bin")) == payload)
            #expect(try await provider.readData("/video.bin") == payload)
            #expect(try await provider.readData("/video.bin", range: 1_000_003..<3_500_000) == payload.subdata(in: 1_000_003..<3_500_000))
        }
    }

    @Test func writesNewFilesAndOverwritesKeepingPermissions() async throws {
        try await withConnection { server, provider in
            try await provider.write("/app.env", data: Data("old".utf8))
            #expect(try server.contents("/app.env") == "old")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: server.url("/app.env").path)

            try await provider.write("/app.env", data: Data("new".utf8))

            #expect(try server.contents("/app.env") == "new")
            #expect(try await provider.stat("/app.env").permissions == 0o600)
            #expect(try server.names(in: .root) == ["app.env"])
        }
    }

    @Test func interruptedUploadLeavesTheOriginalAlone() async throws {
        try await withConnection { server, provider in
            try server.makeFile("/nginx.conf", "original")
            struct Dropped: Error {}
            let interrupted = AsyncThrowingStream<Data, any Error> { continuation in
                continuation.yield(Data("half".utf8))
                continuation.finish(throwing: Dropped())
            }

            await #expect(throws: (any Error).self) {
                try await provider.write("/nginx.conf", from: interrupted)
            }

            #expect(try server.contents("/nginx.conf") == "original")
            // What was sent so far waits in the partial file for a resume.
            #expect(try server.names(in: .root) == [".nginx.conf.bottari-part", "nginx.conf"])
        }
    }

    @Test func refusesToOverwriteAFolderWithAFile() async throws {
        try await withConnection { server, provider in
            try server.makeDirectory("/assets")

            await #expect(throws: ProviderError.isADirectory("/assets")) {
                try await provider.write("/assets", data: Data("oops".utf8))
            }
            #expect(try server.names(in: .root) == ["assets"])
        }
    }

    // MARK: Changing things

    @Test func makeDirectoryReportsClashes() async throws {
        try await withConnection { server, provider in
            try await provider.makeDirectory("/releases")
            #expect(try server.names(in: .root) == ["releases"])

            await #expect(throws: ProviderError.alreadyExists("/releases")) {
                try await provider.makeDirectory("/releases")
            }
        }
    }

    @Test func moveRenamesButRefusesToOverwrite() async throws {
        try await withConnection { server, provider in
            try server.makeFile("/a.txt", "a")
            try server.makeFile("/b.txt", "b")

            await #expect(throws: ProviderError.alreadyExists("/b.txt")) {
                try await provider.move("/a.txt", to: "/b.txt")
            }
            await #expect(throws: ProviderError.notFound("/missing.txt")) {
                try await provider.move("/missing.txt", to: "/c.txt")
            }
            try await provider.move("/a.txt", to: "/c.txt")
            #expect(try server.names(in: .root) == ["b.txt", "c.txt"])
        }
    }

    @Test func deleteRemovesFilesFoldersAndLinksWithoutFollowingThem() async throws {
        try await withConnection { server, provider in
            try server.makeDirectory("/logs/old")
            try server.makeFile("/logs/app.log", "x")
            try server.makeFile("/logs/old/app.1.log", "y")
            try server.makeDirectory("/keep")
            try server.makeFile("/keep/data.txt", "important")
            try FileManager.default.createSymbolicLink(
                atPath: server.url("/shortcut").path,
                withDestinationPath: server.url("/keep").path
            )

            try await provider.delete("/logs")
            try await provider.delete("/shortcut")

            #expect(try server.names(in: .root) == ["keep"])
            #expect(try server.contents("/keep/data.txt") == "important")
            await #expect(throws: ProviderError.notFound("/logs")) {
                try await provider.delete("/logs")
            }
        }
    }
}

@Suite struct SFTPTranslationTests {
    @Test func statusCodesMapToProviderErrors() {
        let path: RemotePath = "/var/www"
        #expect(SFTPFileProvider.translate(.noSuchFile, message: "", path) == .notFound(path))
        #expect(SFTPFileProvider.translate(.permissionDenied, message: "", path) == .permissionDenied(path))
        #expect(SFTPFileProvider.translate(.unsupportedOperation, message: "", path) == .unsupported("SFTP"))
        #expect(SFTPFileProvider.translate(.failure, message: "Failure", path) == .io("Failure"))
        #expect(SFTPFileProvider.translate(.connectionLost, message: "", path) == .disconnected("서버와의 연결이 끊어졌습니다"))
    }

    @Test func ownerComesFromTheLongname() {
        #expect(SFTPFileProvider.owner(fromLongname: "drwxr-xr-x    2 deploy   www-data     4096 Oct 21 18:40 assets") == "deploy")
        #expect(SFTPFileProvider.owner(fromLongname: "") == nil)
    }

    @Test func hostKeyIDMatchesKnownHostsFormat() {
        #expect(SFTPEndpoint(host: "example.com", username: "me").hostKeyID == "example.com")
        #expect(SFTPEndpoint(host: "example.com", port: 2222, username: "me").hostKeyID == "[example.com]:2222")
    }

    @Test func fingerprintLooksLikeSshKeygen() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGb2jq4vM8O3R2wW7xM6kQ6m8r1tq9XvC0u8b7nT0Jx1"
        let fingerprint = KnownHosts.fingerprint(ofOpenSSHKey: key)
        #expect(fingerprint.hasPrefix("SHA256:"))
        #expect(!fingerprint.hasSuffix("="))
        #expect(fingerprint.count == "SHA256:".count + 43)
    }
}

/// Counts calls from any thread.
final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func add() {
        count.withLock { $0 += 1 }
    }
}
