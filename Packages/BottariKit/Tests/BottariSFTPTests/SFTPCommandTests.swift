import BottariCore
import Foundation
import Testing
@testable import BottariSFTP

@Suite(.timeLimit(.minutes(1))) struct SFTPCommandTests {
    func withConnection(commands: Bool = true, _ body: (TestSFTPServer, SFTPFileProvider) async throws -> Void) async throws {
        let server = try await TestSFTPServer.start(commands: commands)
        let provider: SFTPFileProvider
        do {
            provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .password(TestSFTPServer.password), hostKeys: .acceptAnything)
        } catch {
            await server.stop()
            throw error
        }
        do {
            try await body(server, provider)
        } catch {
            await provider.disconnect()
            await server.stop()
            throw error
        }
        await provider.disconnect()
        await server.stop()
    }

    @Test func commandsAreDetectedAndRun() async throws {
        try await withConnection { _, provider in
            #expect(provider.canRunCommands)
            #expect(provider.capabilities.contains([.exec, .serverSideCopy, .checksum]))
            let output = try await provider.run("echo hello")
            #expect(output == "hello\n")
        }
    }

    @Test func aServerWithoutCommandsIsStillUsable() async throws {
        try await withConnection(commands: false) { server, provider in
            #expect(!provider.canRunCommands)
            #expect(!provider.capabilities.contains(.serverSideCopy))
            try server.makeFile("/a.txt", "a")
            #expect(try await provider.list(.root).map(\.name) == ["a.txt"])
        }
    }

    @Test func failingCommandsReportTheirError() async throws {
        try await withConnection { _, provider in
            await #expect {
                _ = try await provider.run("echo broken >&2; exit 3")
            } throws: { error in
                // Real servers send stderr before the exit status; the test server may not.
                guard case ProviderError.io(let message) = error else { return false }
                return message.hasPrefix("서버 명령이 실패했어요 (종료 코드 3)")
            }
        }
    }

    @Test func copiesOnTheServerAndHashesThere() async throws {
        try await withConnection { server, provider in
            try server.makeDirectory("/site/img")
            try server.makeFile("/site/index.html", "hello\n")
            try server.makeFile("/site/img/it's.svg", "<svg/>")

            try await provider.copy("/site", to: "/site-copy")

            #expect(try server.contents("/site-copy/img/it's.svg") == "<svg/>")
            #expect(try await provider.checksum("/site-copy/index.html") == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
        }
    }

    @Test func compressesAndExtractsIntoANewFolder() async throws {
        try await withConnection { server, provider in
            try server.makeDirectory("/logs/old")
            try server.makeFile("/logs/app.log", "app")
            try server.makeFile("/logs/old/-weird.log", "weird")

            try await provider.compress(["/logs/app.log", "/logs/old"], into: "/logs/logs.tar.gz")
            try await provider.extract("/logs/logs.tar.gz", into: "/logs/logs")

            #expect(try server.contents("/logs/logs/app.log") == "app")
            #expect(try server.contents("/logs/logs/old/-weird.log") == "weird")
        }
    }

    @Test func resumesACutOffUploadAndKeepsTheModificationTime() async throws {
        try await withConnection { server, provider in
            struct Dropped: Error {}
            await #expect(throws: (any Error).self) {
                try await provider.write("/movie.mp4", from: AsyncThrowingStream { continuation in
                    continuation.yield(Data("01234".utf8))
                    continuation.finish(throwing: Dropped())
                })
            }
            #expect(try server.names(in: .root) == [".movie.mp4.bottari-part"])

            try await provider.write("/movie.mp4", from: AsyncThrowingStream { continuation in
                continuation.yield(Data("56789".utf8))
                continuation.finish()
            }, resumingAt: 5)

            #expect(try server.contents("/movie.mp4") == "0123456789")
            #expect(try server.names(in: .root) == ["movie.mp4"])
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try await provider.setModified(date, at: "/movie.mp4")
            #expect(try await provider.stat("/movie.mp4").modified == date)
        }
    }

    @Test func quotingSurvivesQuotes() {
        #expect(SFTPFileProvider.quote("it's") == #"'it'\''s'"#)
    }
}
