import BottariCore
import Foundation
import Testing
@testable import BottariTransfer

@MainActor
@Suite(.timeLimit(.minutes(1))) struct TransferQueueTests {
    struct TimedOut: Error {}

    let queue = TransferQueue()
    let mac = MemoryFileProvider("mac")
    let server = MemoryFileProvider("server")

    func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @discardableResult
    func transfer(
        _ kind: TransferKind,
        _ paths: [RemotePath],
        from source: MemoryFileProvider,
        to destination: MemoryFileProvider,
        into folder: RemotePath = .root,
        policy: ConflictPolicy = .ask
    ) async throws -> TransferJob {
        var items: [FileItem] = []
        for path in paths {
            items.append(try await source.stat(path))
        }
        return queue.enqueue(kind, items, from: TransferEndpoint(source), to: TransferEndpoint(destination), into: folder, policy: policy)
    }

    func finished(_ job: TransferJob) async throws -> TransferJob {
        try await eventually { job.state.hasEnded }
        return job
    }

    // MARK: - Copying

    @Test func copiesAFolderTreeAndCountsIt() async throws {
        mac.addFile("/site/index.html", "<h1>hi</h1>")
        mac.addFile("/site/css/app.css", "body{}")
        mac.addFile("/site/img/deep/logo.svg", "<svg/>")
        server.addFolder("/var/www")

        let job = try await finished(try await transfer(.copy, ["/site"], from: mac, to: server, into: "/var/www"))

        #expect(job.state == .finished)
        #expect(job.route == .viaMac)
        #expect(server.tree == [
            "/var/", "/var/www/", "/var/www/site/", "/var/www/site/css/", "/var/www/site/css/app.css",
            "/var/www/site/img/", "/var/www/site/img/deep/", "/var/www/site/img/deep/logo.svg", "/var/www/site/index.html",
        ])
        #expect(server.text("/var/www/site/css/app.css") == "body{}")
        #expect(job.totalFiles == 3 && job.completedFiles == 3)
        #expect(job.totalBytes == 23 && job.transferredBytes == 23)
        #expect(job.fractionCompleted == 1)
        #expect(mac.exists("/site/index.html"))
    }

    @Test func uploadsFromTheMacAndPicksTheRoute() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bottari-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "logs"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 300_000).write(to: folder.appending(path: "logs/big.log"))
        let local = LocalFileProvider()
        let logs = try await local.stat(RemotePath(folder.appending(path: "logs").path))

        let job = queue.enqueue(.copy, [logs], from: TransferEndpoint(local), to: TransferEndpoint(server), into: .root)
        _ = try await finished(job)

        #expect(job.route == .upload)
        #expect(server.data("/logs/big.log") == Data(repeating: 7, count: 300_000))
        #expect(TransferQueue.route(.copy, from: server, to: local) == .download)
        #expect(TransferQueue.route(.copy, from: local, to: local) == .withinLocation)
        #expect(TransferQueue.route(.copy, from: server, to: server) == .viaMac)
        #expect(TransferQueue.route(.move, from: server, to: server) == .withinLocation)
    }

    @Test func linkedFoldersAreNotFollowed() async throws {
        mac.addFile("/project/main.swift", "print()")
        mac.addFile("/project/node_modules/huge.js", "…")
        mac.addFolder("/project/node_modules", isLink: true)

        let job = try await finished(try await transfer(.copy, ["/project"], from: mac, to: server))

        #expect(server.tree == ["/project/", "/project/main.swift"])
        #expect(job.skippedFiles == 1)
    }

    @Test func atMostTheAllowedNumberRunAtOnce() async throws {
        mac.state.withLock { $0.chunkDelay = .milliseconds(10) }
        for index in 0..<8 {
            mac.addFile(RemotePath("/batch/\(index).txt"), String(repeating: "x", count: 10_000))
        }
        queue.maxConcurrentTransfers = 2

        _ = try await finished(try await transfer(.copy, ["/batch"], from: mac, to: server))

        #expect(server.state.withLock { $0.mostWritesAtOnce } == 2)
        #expect(server.tree.count == 9)
    }

    // MARK: - Name clashes

    @Test(arguments: [
        (ConflictPolicy.skip, "old"),
        (.overwrite, "new"),
        (.overwriteIfNewer, "new"),
    ])
    func policiesSettleClashesWithoutAsking(policy: ConflictPolicy, expected: String) async throws {
        mac.addFile("/a.txt", "new", modified: Date(timeIntervalSince1970: 2_000_000_000))
        server.addFile("/a.txt", "old", modified: Date(timeIntervalSince1970: 1_000_000_000))

        let job = try await finished(try await transfer(.copy, ["/a.txt"], from: mac, to: server, policy: policy))

        #expect(job.state == .finished)
        #expect(server.text("/a.txt") == expected)
        #expect(job.skippedFiles == (expected == "old" ? 1 : 0))
    }

    @Test func overwriteIfNewerKeepsANewerDestination() async throws {
        mac.addFile("/a.txt", "stale", modified: Date(timeIntervalSince1970: 1_000_000_000))
        server.addFile("/a.txt", "fresh", modified: Date(timeIntervalSince1970: 2_000_000_000))

        _ = try await finished(try await transfer(.copy, ["/a.txt"], from: mac, to: server, policy: .overwriteIfNewer))

        #expect(server.text("/a.txt") == "fresh")
    }

    @Test func askingWaitsAndKeepBothAppliesToTheRest() async throws {
        mac.addFile("/docs/a.txt", "new a")
        mac.addFile("/docs/b.txt", "new b")
        mac.addFile("/docs/c.txt", "new c")
        server.addFile("/docs/a.txt", "old a")
        server.addFile("/docs/b.txt", "old b")
        server.addFile("/docs/a 2.txt", "taken")

        let job = try await transfer(.copy, ["/docs"], from: mac, to: server)
        try await eventually { job.pendingConflict != nil }
        #expect(job.state == .running)
        #expect(job.pendingConflict?.existing.size == 5)

        queue.answer(.keepBoth, for: job, applyingToAll: true)
        _ = try await finished(job)

        #expect(server.text("/docs/a.txt") == "old a")
        #expect(server.text("/docs/a 3.txt") == "new a")
        #expect(server.text("/docs/b 2.txt") == "new b")
        #expect(server.text("/docs/c.txt") == "new c")
        #expect(job.completedFiles == 3)
    }

    @Test func answeringOneAtATime() async throws {
        mac.addFile("/a.txt", "new a")
        mac.addFile("/b.txt", "new b")
        server.addFile("/a.txt", "old a")
        server.addFile("/b.txt", "old b")
        queue.maxConcurrentTransfers = 1

        let job = try await transfer(.copy, ["/a.txt", "/b.txt"], from: mac, to: server)
        try await eventually { job.pendingConflict?.incoming.name == "a.txt" }
        queue.answer(.overwrite, for: job)
        try await eventually { job.pendingConflict?.incoming.name == "b.txt" }
        queue.answer(.skip, for: job)
        _ = try await finished(job)

        #expect(server.text("/a.txt") == "new a")
        #expect(server.text("/b.txt") == "old b")
    }

    @Test func aFileNeverReplacesAFolder() async throws {
        mac.addFile("/assets", "a file")
        server.addFolder("/assets")

        let job = try await finished(try await transfer(.copy, ["/assets"], from: mac, to: server, policy: .overwrite))

        #expect(job.state == .failed)
        #expect(job.failures.count == 1)
        #expect(server.tree == ["/assets/"])
    }

    // MARK: - Moving

    @Test func movingElsewhereRemovesOriginalsAndEmptiedFolders() async throws {
        mac.addFile("/out/keep/a.txt", "a")
        mac.addFile("/out/keep/b.txt", "b")
        mac.addFile("/out/clash/c.txt", "c")
        server.addFile("/out/clash/c.txt", "existing")

        let job = try await finished(try await transfer(.move, ["/out"], from: mac, to: server, policy: .skip))

        #expect(job.state == .finished)
        #expect(server.text("/out/keep/a.txt") == "a")
        #expect(server.text("/out/clash/c.txt") == "existing")
        // The skipped file stays where it was, and so do the folders holding it.
        #expect(mac.tree == ["/out/", "/out/clash/", "/out/clash/c.txt"])
    }

    @Test func movingWithinALocationRenamesWholeFolders() async throws {
        server.addFile("/releases/v1/app.tar", "v1")
        server.addFolder("/archive")

        let job = try await finished(try await transfer(.move, ["/releases/v1"], from: server, to: server, into: "/archive"))

        #expect(job.route == .withinLocation)
        #expect(job.totalFiles == 1)
        #expect(server.tree == ["/archive/", "/archive/v1/", "/archive/v1/app.tar", "/releases/"])
    }

    @Test func movingWithinALocationMergesIntoAnExistingFolder() async throws {
        server.addFile("/new/site/index.html", "new")
        server.addFile("/new/site/extra.css", "css")
        server.addFile("/live/site/index.html", "old")
        server.addFile("/live/site/keep.txt", "keep")

        let job = try await finished(try await transfer(.move, ["/new/site"], from: server, to: server, into: "/live", policy: .overwrite))

        #expect(job.state == .finished)
        #expect(server.text("/live/site/index.html") == "new")
        #expect(server.text("/live/site/extra.css") == "css")
        #expect(server.text("/live/site/keep.txt") == "keep")
        #expect(server.tree.filter { $0.hasPrefix("/new") } == ["/new/"])
    }

    @Test func copyingIntoItsOwnFolderKeepsBoth() async throws {
        server.addFile("/notes.md", "# notes")

        _ = try await finished(try await transfer(.copy, ["/notes.md"], from: server, to: server))

        #expect(server.text("/notes.md") == "# notes")
        #expect(server.text("/notes 2.md") == "# notes")
    }

    @Test func aFolderCannotGoInsideItself() async throws {
        server.addFile("/a/b/file", "x")

        let job = try await finished(try await transfer(.move, ["/a"], from: server, to: server, into: "/a/b"))

        #expect(job.state == .failed)
        #expect(server.tree == ["/a/", "/a/b/", "/a/b/file"])
    }

    // MARK: - Failing, pausing, cancelling

    @Test func failedFilesCanBeRetried() async throws {
        mac.addFile("/up/good.txt", "good")
        mac.addFile("/up/bad.txt", "bad")
        server.state.withLock { $0.failingWrites = ["bad.txt"] }

        let job = try await finished(try await transfer(.copy, ["/up"], from: mac, to: server))
        #expect(job.state == .failed)
        #expect(job.failures.map(\.path) == ["/up/bad.txt"])
        #expect(job.completedFiles == 1)

        server.state.withLock { $0.failingWrites = [] }
        queue.retryFailures(of: job)
        try await eventually { job.state == .finished }

        #expect(server.text("/up/bad.txt") == "bad")
        #expect(job.failures.isEmpty && job.completedFiles == 2)
    }

    @Test func failedFilesCanBeSkipped() async throws {
        mac.addFile("/bad.txt", "bad")
        server.state.withLock { $0.failingWrites = ["bad.txt"] }
        var changes = 0
        queue.onJobsChanged = { changes += 1 }

        let job = try await finished(try await transfer(.copy, ["/bad.txt"], from: mac, to: server))
        queue.skipFailures(of: job)

        #expect(job.state == .finished)
        #expect(job.skippedFiles == 1)
        #expect(changes == 2)
    }

    @Test func pausingStopsAndResumingStartsCutOffFilesOver() async throws {
        let payload = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0) })
        mac.addFile("/movie.mp4", payload)
        mac.state.withLock { state in
            state.chunkSize = 1000
            state.chunkDelay = .milliseconds(5)
        }

        let job = try await transfer(.copy, ["/movie.mp4"], from: mac, to: server)
        try await eventually { job.inFlightBytes > 0 }
        queue.pause(job)
        try await eventually { job.running.isEmpty }

        #expect(job.state == .paused)
        #expect(!server.exists("/movie.mp4"))
        #expect(job.pending.count == 1)

        mac.state.withLock { $0.chunkDelay = nil }
        queue.resume(job)
        _ = try await finished(job)

        #expect(job.state == .finished)
        #expect(server.data("/movie.mp4") == payload)
        #expect(job.transferredBytes == 40_000)
    }

    @Test func cancellingLeavesNothingHalfWritten() async throws {
        mac.addFile("/movie.mp4", Data(count: 40_000))
        mac.addFile("/later.txt", "later")
        mac.state.withLock { state in
            state.chunkSize = 1000
            state.chunkDelay = .milliseconds(5)
        }
        queue.maxConcurrentTransfers = 1

        let job = try await transfer(.copy, ["/movie.mp4", "/later.txt"], from: mac, to: server)
        try await eventually { job.inFlightBytes > 0 }
        queue.cancel(job)
        try await eventually { job.running.isEmpty }

        #expect(job.state == .cancelled)
        #expect(server.tree.isEmpty)
    }

    @Test func freeNamesGoBeforeTheExtension() {
        #expect(RemotePath.freeName(for: "a.txt", isDirectory: false, taken: ["a 2.txt"]) == "a 3.txt")
        #expect(RemotePath.freeName(for: ".env", isDirectory: false, taken: []) == ".env 2")
        #expect(RemotePath.freeName(for: "photos.2024", isDirectory: true, taken: []) == "photos.2024 2")
        #expect(RemotePath.freeName(for: "Makefile", isDirectory: false, taken: []) == "Makefile 2")
    }
}
