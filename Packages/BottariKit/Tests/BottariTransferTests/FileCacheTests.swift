import BottariCore
import Foundation
import Synchronization
import Testing
@testable import BottariTransfer

@Suite struct FileCacheTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "bottari-cache-\(UUID().uuidString)")
    let server = MemoryFileProvider("server")

    @Test func downloadsOnceAndReusesTheCopy() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        server.addFile("/photos/cat.jpg", "meow")
        let cache = FileCache(directory: directory)
        let item = try await server.stat("/photos/cat.jpg")
        let seen = Mutex<[Int64]>([])

        let url = try await cache.localURL(for: item, from: server) { bytes in seen.withLock { $0.append(bytes) } }
        let again = try await cache.localURL(for: item, from: server)

        #expect(url == again)
        #expect(url.lastPathComponent == "cat.jpg")
        #expect(try String(contentsOf: url, encoding: .utf8) == "meow")
        #expect(server.state.withLock { $0.readOffsets } == [0])
        #expect(seen.withLock { $0 } == [4])
    }

    @Test func aChangedFileIsFetchedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileCache(directory: directory)
        server.addFile("/notes.md", "v1", modified: Date(timeIntervalSince1970: 1))
        let first = try await cache.localURL(for: try await server.stat("/notes.md"), from: server)

        server.addFile("/notes.md", "v2 longer", modified: Date(timeIntervalSince1970: 2))
        let second = try await cache.localURL(for: try await server.stat("/notes.md"), from: server)

        #expect(first != second)
        #expect(try String(contentsOf: second, encoding: .utf8) == "v2 longer")
    }

    @Test func filesOnTheMacAreUsedInPlace() async throws {
        let cache = FileCache(directory: directory)
        let item = FileItem(path: "/etc/hosts", kind: .file, size: 1)
        #expect(try await cache.localURL(for: item, from: LocalFileProvider()) == URL(fileURLWithPath: "/etc/hosts"))
    }

    @Test func theOldestCopiesGoWhenOverTheLimit() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileCache(directory: directory, limit: 10)
        server.addFile("/a", "123456")
        server.addFile("/b", "123456")
        let a = try await cache.localURL(for: try await server.stat("/a"), from: server)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: a.path)
        let b = try await cache.localURL(for: try await server.stat("/b"), from: server)

        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(await cache.size() == 6)
    }
}
