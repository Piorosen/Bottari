import Foundation
import Testing
@testable import BottariCore

@Suite struct LocalFileProviderTests {
    let provider = LocalFileProvider()

    /// A fresh directory per test; the caller removes it with `cleanUp`.
    func makeTempDirectory() throws -> RemotePath {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BottariTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return RemotePath(url.path)
    }

    func cleanUp(_ dir: RemotePath) {
        try? FileManager.default.removeItem(atPath: dir.string)
    }

    func setMode(_ mode: Int, _ path: RemotePath) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path.string)
    }

    @Test func listsDirectoriesFirstInFinderOrder() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        try await provider.makeDirectory(dir.appending("zeta"))
        try await provider.write(dir.appending("file10.txt"), data: Data("10".utf8))
        try await provider.write(dir.appending("file2.txt"), data: Data("2".utf8))

        let names = try await provider.list(dir).map(\.name)
        #expect(names == ["zeta", "file2.txt", "file10.txt"])
    }

    @Test func statReportsKindSizeOwnerAndPermissions() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let file = dir.appending("hello.txt")
        try await provider.write(file, data: Data("hello".utf8))
        try setMode(0o640, file)

        let item = try await provider.stat(file)
        #expect(item.kind == .file)
        #expect(item.size == 5)
        #expect(item.owner == NSUserName())
        #expect(item.permissionString == "-rw-r-----")
        #expect(try await provider.stat(dir).size == nil)
    }

    @Test func readsWholeFileAndByteRanges() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let file = dir.appending("digits.txt")
        try await provider.write(file, data: Data("0123456789".utf8))

        #expect(try await provider.readData(file) == Data("0123456789".utf8))
        #expect(try await provider.readData(file, range: 2..<5) == Data("234".utf8))
        #expect(try await provider.readData(file, range: 8..<100) == Data("89".utf8))
    }

    @Test func streamsLargeFilesInChunks() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let file = dir.appending("big.bin")
        let payload = Data((0..<(LocalFileProvider.chunkSize * 3 + 10)).map { UInt8(truncatingIfNeeded: $0) })
        try await provider.write(file, data: payload)

        var chunks = 0
        var received = Data()
        for try await chunk in provider.read(file, range: nil) {
            chunks += 1
            received.append(chunk)
        }
        #expect(chunks == 4)
        #expect(received == payload)
    }

    @Test func overwriteKeepsPermissionsAndLeavesNoTempFile() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let file = dir.appending("app.env")
        try await provider.write(file, data: Data("old".utf8))
        try setMode(0o600, file)

        try await provider.write(file, data: Data("new".utf8))

        #expect(try await provider.readData(file) == Data("new".utf8))
        #expect(try await provider.stat(file).permissions == 0o600)
        #expect(try await provider.list(dir).map(\.name) == ["app.env"])
    }

    @Test func failedWriteLeavesOriginalUntouched() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let file = dir.appending("nginx.conf")
        try await provider.write(file, data: Data("original".utf8))

        struct Dropped: Error {}
        let interrupted = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(Data("par".utf8))
            continuation.finish(throwing: Dropped())
        }
        await #expect(throws: (any Error).self) {
            try await provider.write(file, from: interrupted)
        }

        #expect(try await provider.readData(file) == Data("original".utf8))
        // The bytes written so far wait in the partial file for a resume.
        #expect(try await provider.list(dir).map(\.name) == [".nginx.conf.bottari-part", "nginx.conf"])
        await provider.discardPartialWrite(to: file)
        #expect(try await provider.list(dir).map(\.name) == ["nginx.conf"])
    }

    @Test func aCutOffWriteResumesFromItsPartialFile() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let file = dir.appending("video.mp4")
        struct Dropped: Error {}
        let firstHalf = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(Data("01234".utf8))
            continuation.finish(throwing: Dropped())
        }
        await #expect(throws: (any Error).self) { try await provider.write(file, from: firstHalf) }
        let partial = try await provider.stat(file.partialWritePath)
        #expect(partial.size == 5)

        try await provider.write(file, from: AsyncThrowingStream { continuation in
            continuation.yield(Data("56789".utf8))
            continuation.finish()
        }, resumingAt: 5)

        #expect(try await provider.readData(file) == Data("0123456789".utf8))
        #expect(try await provider.list(dir).map(\.name) == ["video.mp4"])
    }

    @Test func checksumAndModificationTime() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let file = dir.appending("hello.txt")
        try await provider.write(file, data: Data("hello\n".utf8))

        #expect(try await provider.checksum(file) == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await provider.setModified(date, at: file)
        #expect(try await provider.stat(file).modified == date)
    }

    @Test func makeDirectoryTwiceThrowsAlreadyExists() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let folder = dir.appending("releases")
        try await provider.makeDirectory(folder)

        await #expect(throws: ProviderError.alreadyExists(folder)) {
            try await provider.makeDirectory(folder)
        }
    }

    @Test func moveRenamesButRefusesToOverwrite() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let a = dir.appending("a.txt"), b = dir.appending("b.txt"), c = dir.appending("c.txt")
        try await provider.write(a, data: Data("a".utf8))
        try await provider.write(b, data: Data("b".utf8))

        await #expect(throws: ProviderError.alreadyExists(b)) {
            try await provider.move(a, to: b)
        }
        try await provider.move(a, to: c)
        #expect(try await provider.list(dir).map(\.name) == ["b.txt", "c.txt"])
    }

    @Test func copyDuplicatesDirectoriesRecursively() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let source = dir.appending("v1.4.2")
        try await provider.makeDirectory(source)
        try await provider.write(source.appending("index.html"), data: Data("<html>".utf8))

        try await provider.copy(source, to: dir.appending("v1.4.2 copy"))

        #expect(try await provider.readData(dir.appending("v1.4.2 copy/index.html")) == Data("<html>".utf8))
        #expect(try await provider.list(source).count == 1)
    }

    @Test func deleteRemovesDirectoriesRecursively() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let logs = dir.appending("logs")
        try await provider.makeDirectory(logs)
        try await provider.write(logs.appending("app.log"), data: Data("x".utf8))

        try await provider.delete(logs)

        #expect(try await provider.list(dir).isEmpty)
    }

    @Test func missingPathsThrowNotFound() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let missing = dir.appending("nope")

        await #expect(throws: ProviderError.notFound(missing)) { try await provider.list(missing) }
        await #expect(throws: ProviderError.notFound(missing)) { try await provider.stat(missing) }
        await #expect(throws: ProviderError.notFound(missing)) { try await provider.readData(missing) }
        await #expect(throws: ProviderError.notFound(missing)) { try await provider.delete(missing) }
    }

    @Test func wrongKindThrowsSpecificErrors() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let file = dir.appending("README.md")
        try await provider.write(file, data: Data("# hi".utf8))

        await #expect(throws: ProviderError.notADirectory(file)) { try await provider.list(file) }
        await #expect(throws: ProviderError.isADirectory(dir)) { try await provider.readData(dir) }
    }

    @Test func symlinkToDirectoryOpensLikeADirectory() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }
        let target = dir.appending("v1.4.2")
        try await provider.makeDirectory(target)
        try FileManager.default.createSymbolicLink(atPath: dir.appending("latest").string, withDestinationPath: target.string)

        let link = try await provider.stat(dir.appending("latest"))
        #expect(link.isDirectory)
        #expect(link.isSymbolicLink)
    }

    @Test func listingDoesNotFollowLinksIntoGuardedFolders() async throws {
        let home = try makeTempDirectory()
        defer { cleanUp(home) }
        let provider = LocalFileProvider(home: home, privacy: PrivacyGuard(home: home))
        try await provider.makeDirectory(home.appending("Desktop"))
        try await provider.makeDirectory(home.appending("Desktop/project"))
        try await provider.makeDirectory(home.appending("Projects"))
        let links = home.appending("links")
        try await provider.makeDirectory(links)
        try FileManager.default.createSymbolicLink(atPath: links.appending("desk").string, withDestinationPath: "../Desktop/project")
        try FileManager.default.createSymbolicLink(atPath: links.appending("work").string, withDestinationPath: home.appending("Projects").string)

        let listed = try await provider.list(links)

        let desk = try #require(listed.first { $0.name == "desk" })
        #expect(desk.isSymbolicLink && desk.kind == .other)
        #expect(listed.first { $0.name == "work" }?.isDirectory == true)
        // Opening the link on purpose follows it.
        #expect(try await provider.stat(links.appending("desk")).isDirectory)
    }

    @Test func guardedFoldersAreTheProtectedOnes() {
        let privacy = PrivacyGuard(home: "/Users/me")
        #expect(privacy.isGuardedFolder("/Users/me/Downloads"))
        #expect(privacy.isGuardedFolder("/Volumes/USB"))
        #expect(!privacy.isGuardedFolder("/Users/me/Downloads/a"))
        #expect(privacy.isGuarded("/Users/me/Library/CloudStorage/Dropbox/x"))
        #expect(!privacy.isGuarded("/Users/me/Library/Preferences"))
        #expect(!privacy.isGuarded("/Users/me"))
        #expect(!privacy.isGuarded("/Volumes"))
    }
}
