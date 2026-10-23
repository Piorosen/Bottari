import BottariCore
import BottariTransfer
import Foundation
import Testing
@testable import BottariSFTP

@Suite(.timeLimit(.minutes(1))) struct TransferIntegrationTests {
    struct TimedOut: Error {}

    @MainActor
    func ended(_ job: TransferJob) async throws -> TransferJob {
        let deadline = ContinuousClock.now + .seconds(20)
        while !job.state.hasEnded {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
        return job
    }

    func connect(_ server: TestSFTPServer) async throws -> SFTPFileProvider {
        try await SFTPFileProvider.connect(to: server.endpoint, credential: .password(TestSFTPServer.password), hostKeys: .acceptAnything)
    }

    @Test func uploadsCopiesBetweenServersAndMovesBack() async throws {
        let first = try await TestSFTPServer.start()
        let second = try await TestSFTPServer.start()
        let folder = FileManager.default.temporaryDirectory.appending(path: "bottari-transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "site/img"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "down"), withIntermediateDirectories: true)
        try Data("<h1>hi</h1>".utf8).write(to: folder.appending(path: "site/index.html"))
        let photo = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try photo.write(to: folder.appending(path: "site/img/photo.jpg"))

        let a = try await connect(first)
        let b = try await connect(second)
        do {
            try await transfer(between: a, b, firstRoot: first.url(.root), secondRoot: second.url(.root), folder: folder, photo: photo)
        } catch {
            await a.disconnect()
            await b.disconnect()
            await first.stop()
            await second.stop()
            throw error
        }
        await a.disconnect()
        await b.disconnect()
        await first.stop()
        await second.stop()
    }

    /// Mac → first server, first → second server, then a move from the second back to the Mac.
    @MainActor
    func transfer(between a: SFTPFileProvider, _ b: SFTPFileProvider, firstRoot: URL, secondRoot: URL, folder: URL, photo: Data) async throws {
        let mac = LocalFileProvider()
        let queue = TransferQueue()

        let site = try await mac.stat(RemotePath(folder.appending(path: "site").path))
        let upload = try await ended(queue.enqueue(.copy, [site], from: TransferEndpoint(mac), to: TransferEndpoint(a), into: .root))
        #expect(upload.state == .finished && upload.route == .upload)
        #expect(try String(contentsOf: firstRoot.appending(path: "site/index.html"), encoding: .utf8) == "<h1>hi</h1>")
        #expect(try Data(contentsOf: firstRoot.appending(path: "site/img/photo.jpg")) == photo)

        let onFirst = try await a.list(.root).filter { $0.name == "site" }
        let relay = try await ended(queue.enqueue(.copy, onFirst, from: TransferEndpoint(a), to: TransferEndpoint(b), into: .root))
        #expect(relay.state == .finished && relay.route == .viaMac)
        #expect(try Data(contentsOf: secondRoot.appending(path: "site/img/photo.jpg")) == photo)
        #expect(relay.transferredBytes == Int64(photo.count + 11))

        let photos = try await b.list("/site/img")
        let down = RemotePath(folder.appending(path: "down").path)
        let move = try await ended(queue.enqueue(.move, photos, from: TransferEndpoint(b), to: TransferEndpoint(mac), into: down))
        #expect(move.state == .finished && move.route == .download)
        #expect(try Data(contentsOf: folder.appending(path: "down/photo.jpg")) == photo)
        #expect(try FileManager.default.contentsOfDirectory(atPath: secondRoot.appending(path: "site/img").path).isEmpty)
    }
}
