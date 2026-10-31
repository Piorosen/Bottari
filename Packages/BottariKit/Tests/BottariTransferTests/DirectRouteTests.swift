import BottariCore
import Foundation
import Synchronization
import Testing
@testable import BottariTransfer

/// The queue's side of server-to-server copies, with a stand-in for the
/// servers: one memory provider copying into another, as tar over ssh would.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct DirectRouteTests {
    let queue = TransferQueue()
    let prod = MemoryFileProvider("prod")
    let backup = MemoryFileProvider("backup")
    let mac = MemoryFileProvider("mac")
    /// Items the direct route was asked for, by path; set to fail the next ones as unreachable.
    let sent = Sent()

    final class Sent: Sendable {
        private let state = Mutex<(paths: [String], unreachable: Bool)>(([], false))

        func withLock<T>(_ body: (inout (paths: [String], unreachable: Bool)) -> T) -> T {
            state.withLock { body(&$0) }
        }
    }

    init() {
        let sent = sent
        queue.directRoute = DirectRoute(
            canSend: { from, to in from.locationID != "memory://mac" && to.locationID != "memory://mac" },
            send: { item, from, to, folder in
                let unreachable = sent.withLock { state in
                    state.paths.append(item.path.string)
                    return state.unreachable
                }
                if unreachable { throw DirectRouteUnavailable(reason: "no route to host") }
                guard let from = from as? MemoryFileProvider, let to = to as? MemoryFileProvider else { return }
                let entries = from.state.withLock { $0.entries }
                to.state.withLock { state in
                    for (path, entry) in entries where path == item.path || item.path.isAncestor(of: path) {
                        let relative = String(path.string.dropFirst(item.path.parent!.string == "/" ? 1 : item.path.parent!.string.count + 1))
                        state.entries[folder.appending(relative)] = entry
                    }
                }
            }
        )
    }

    func finished(_ job: TransferJob) async throws -> TransferJob {
        let deadline = ContinuousClock.now + .seconds(10)
        while !job.state.hasEnded {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
        return job
    }

    func copy(_ paths: [RemotePath], from: MemoryFileProvider, to: MemoryFileProvider, into folder: RemotePath = .root, policy: ConflictPolicy = .ask) async throws -> TransferJob {
        var items: [FileItem] = []
        for path in paths { items.append(try await from.stat(path)) }
        return try await finished(queue.enqueue(.copy, items, from: TransferEndpoint(from), to: TransferEndpoint(to), into: folder, policy: policy))
    }

    @Test func serversSendStraightToEachOther() async throws {
        prod.addFile("/site/index.html", "<h1>hi</h1>")
        prod.addFile("/site/img/logo.svg", "<svg/>")
        prod.addFile("/db.sql", "dump")

        let job = try await copy(["/site", "/db.sql"], from: prod, to: backup)

        #expect(job.route == .direct)
        #expect(job.state == .finished)
        // Sent side by side, so in either order.
        #expect(sent.withLock { $0.paths }.sorted() == ["/db.sql", "/site"])
        #expect(backup.text("/site/img/logo.svg") == "<svg/>")
        #expect(backup.text("/db.sql") == "dump")
        // Nothing was read through the Mac.
        #expect(prod.state.withLock { $0.readOffsets }.isEmpty)
    }

    @Test func placesTheRouteTurnsDownGoThroughTheMac() async throws {
        mac.addFile("/a.txt", "a")
        let job = try await copy(["/a.txt"], from: mac, to: backup)
        #expect(job.route == .viaMac)
        #expect(backup.text("/a.txt") == "a")
        #expect(sent.withLock { $0.paths }.isEmpty)
    }

    @Test func anUnreachableDestinationFallsBackToTheMac() async throws {
        sent.withLock { $0.unreachable = true }
        prod.addFile("/one.txt", "1")
        prod.addFile("/two.txt", "2")
        queue.maxConcurrentTransfers = 1

        let job = try await copy(["/one.txt", "/two.txt"], from: prod, to: backup)

        #expect(job.state == .finished)
        #expect(job.route == .viaMac)
        #expect(backup.text("/one.txt") == "1" && backup.text("/two.txt") == "2")
        // Only the first item tried the direct route.
        #expect(sent.withLock { $0.paths } == ["/one.txt"])
        // Planned again through the Mac, but counted once.
        #expect(job.totalFiles == 2 && job.completedFiles == 2)
        #expect(job.totalBytes == 2 && job.fractionCompleted == 1)
    }

    @Test func anExistingFolderIsMergedItemByItem() async throws {
        prod.addFile("/site/index.html", "new")
        prod.addFile("/site/about.html", "about")
        backup.addFile("/site/index.html", "old")

        let job = try await copy(["/site"], from: prod, to: backup, policy: .skip)

        #expect(job.state == .finished)
        // The clash was settled by the policy; only the new file went over.
        #expect(sent.withLock { $0.paths } == ["/site/about.html"])
        #expect(backup.text("/site/index.html") == "old")
        #expect(backup.text("/site/about.html") == "about")
        #expect(job.skippedFiles == 1)
    }

    @Test func turningTheRouteOffMidwaySendsTheRestThroughTheMac() async throws {
        prod.addFile("/a.txt", "a")
        let job = queue.enqueue(.copy, [try await prod.stat("/a.txt")], from: TransferEndpoint(prod), to: TransferEndpoint(backup), into: .root)
        queue.directRoute = nil
        _ = try await finished(job)
        #expect(job.route == .viaMac)
        #expect(backup.text("/a.txt") == "a")
        #expect(sent.withLock { $0.paths }.isEmpty)
    }

    @Test func aRenamedCopyGoesThroughTheMac() async throws {
        prod.addFile("/report.txt", "new")
        backup.addFile("/report.txt", "old")
        let job = queue.enqueue(.copy, [try await prod.stat("/report.txt")], from: TransferEndpoint(prod), to: TransferEndpoint(backup), into: .root)
        let deadline = ContinuousClock.now + .seconds(10)
        while job.pendingConflict == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        queue.answer(.keepBoth, for: job)
        _ = try await finished(job)

        #expect(job.state == .finished)
        #expect(backup.text("/report.txt") == "old")
        #expect(backup.text("/report 2.txt") == "new")
        // tar on the server keeps names, so the renamed copy was streamed.
        #expect(sent.withLock { $0.paths }.isEmpty)
    }
}
