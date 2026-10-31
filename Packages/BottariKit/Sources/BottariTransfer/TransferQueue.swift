import BottariCore
import Foundation
import Observation

/// Every copy and move the user started. Files are transferred a few at a
/// time across all jobs, oldest job first.
@MainActor
@Observable
public final class TransferQueue {
    public private(set) var jobs: [TransferJob] = []
    /// Files transferred at the same time, across all jobs.
    public var maxConcurrentTransfers = 3 {
        didSet { pump() }
    }
    /// Compare SHA-256 on both sides after each file, where both can compute it
    /// without sending the file again. Applies to jobs started afterwards.
    public var verifiesChecksums = false
    /// Called when a job ends or is removed, e.g. to close connections nothing uses any more.
    @ObservationIgnored public var onJobsChanged: (() -> Void)?
    /// Called whenever jobs' records change: a file done, a job started,
    /// paused or ended. Saving `jobs.compactMap(\.record)` then lets them carry
    /// on after a restart.
    @ObservationIgnored public var onCheckpoint: (() -> Void)?
    /// How to send from one server straight to another; nil sends everything
    /// between servers through the Mac. Applies to jobs started afterwards.
    @ObservationIgnored public var directRoute: DirectRoute?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init() {}

    public var bytesPerSecond: Double {
        jobs.reduce(0) { $0 + ($1.state == .running ? $1.bytesPerSecond : 0) }
    }

    /// Jobs that are running or may still run, including failed ones that can be retried.
    public var unfinishedJobs: [TransferJob] {
        jobs.filter { $0.state != .finished && $0.state != .cancelled }
    }

    /// Copies or moves `items` (files or folders from `source`) into `folder` at `destination`.
    @discardableResult
    public func enqueue(
        _ kind: TransferKind,
        _ items: [FileItem],
        from source: TransferEndpoint,
        to destination: TransferEndpoint,
        into folder: RemotePath,
        policy: ConflictPolicy = .ask
    ) -> TransferJob {
        let job = TransferJob(
            kind: kind,
            items: items,
            source: source,
            destination: destination,
            folder: folder,
            route: route(kind, from: source.provider, to: destination.provider),
            policy: policy
        )
        job.verifiesChecksums = verifiesChecksums
        jobs.append(job)
        Log.transfer.info("\(job.logName): \(items.count)개 항목, \(source.name) → \(destination.name):\(folder), \(job.route)")
        Task { [self] in await prepare(job) }
        onCheckpoint?()
        return job
    }

    /// Carries on with a job saved before the app quit. Files it had done are
    /// left alone, ones it had cut off continue from their partial copies,
    /// and items a move had already taken away are counted as done.
    @discardableResult
    public func resume(_ record: TransferRecord, from source: TransferEndpoint, to destination: TransferEndpoint) async -> TransferJob {
        var items: [FileItem] = []
        var gone: [RemotePath] = []
        for path in record.items {
            if let item = try? await source.provider.stat(path) {
                items.append(item)
            } else {
                gone.append(path)
            }
        }
        let job = TransferJob(
            id: record.id,
            kind: record.kind,
            items: items,
            source: source,
            destination: destination,
            folder: record.folder,
            route: route(record.kind, from: source.provider, to: destination.provider),
            policy: record.policy
        )
        job.verifiesChecksums = record.verifiesChecksums
        job.resumedDone = Set(record.done)
        job.resumedUnfinished = Set(record.unfinished)
        job.resumedVersions = Dictionary((record.unfinishedVersions ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        Log.transfer.info("\(job.logName): 지난번에 끝나지 않은 전송을 이어서 시작 (완료 \(record.done.count)개, 이어받을 파일 \(record.unfinished.count)개)")
        for path in gone where record.kind == .copy {
            job.failures.append(TransferFailure(path: path, message: String(localized: "원본을 찾을 수 없습니다: \(path.string)")))
        }
        jobs.append(job)
        Task { [self] in await prepare(job) }
        onCheckpoint?()
        return job
    }

    /// The route a new job takes, straight between servers where `directRoute` allows.
    private func route(_ kind: TransferKind, from source: any FileProvider, to destination: any FileProvider) -> TransferRoute {
        let route = Self.route(kind, from: source, to: destination)
        guard route == .viaMac, let directRoute, directRoute.canSend(source, destination) else { return route }
        return .direct
    }

    public static func route(_ kind: TransferKind, from source: any FileProvider, to destination: any FileProvider) -> TransferRoute {
        if source.locationID == destination.locationID {
            if kind == .move || source.capabilities.contains(.serverSideCopy) { return .withinLocation }
            return source.isLocal ? .local : .viaMac
        }
        if source.isLocal { return .upload }
        if destination.isLocal { return .download }
        return .viaMac
    }

    // MARK: - Controls

    /// Settles the job's oldest name clash, or every waiting one and all later ones.
    public func answer(_ answer: ConflictAnswer, for job: TransferJob, applyingToAll: Bool = false) {
        guard !job.questions.isEmpty else { return }
        if applyingToAll {
            job.rememberedAnswer = answer
            let questions = job.questions
            job.questions = []
            for question in questions {
                question.answer.resume(returning: answer)
            }
        } else {
            job.questions.removeFirst().answer.resume(returning: answer)
        }
    }

    /// Stops the job's transfers; files cut off midway start over on resume.
    public func pause(_ job: TransferJob) {
        guard [.queued, .preparing, .running].contains(job.state) else { return }
        job.state = .paused
        job.bytesPerSecond = 0
        for running in job.running.values {
            running.task.cancel()
        }
        onCheckpoint?()
    }

    public func resume(_ job: TransferJob) {
        guard job.state == .paused else { return }
        job.state = job.isPreparing ? .preparing : .running
        job.lastSample = nil
        startTicker()
        pump()
        onCheckpoint?()
    }

    public func pauseAll() {
        jobs.forEach(pause)
    }

    public func resumeAll() {
        jobs.forEach(resume)
    }

    public func cancel(_ job: TransferJob) {
        guard !job.state.hasEnded else { return }
        job.state = .cancelled
        job.bytesPerSecond = 0
        discardPartials(of: job.pending, in: job)
        job.pending.removeAll()
        for running in job.running.values {
            running.task.cancel()
        }
        let questions = job.questions
        job.questions = []
        for question in questions {
            question.answer.resume(returning: .skip)
        }
        if job.running.isEmpty { onJobsChanged?() }
        onCheckpoint?()
    }

    /// Tries the failed files and folders again.
    public func retryFailures(of job: TransferJob) {
        guard !job.failures.isEmpty, job.state != .cancelled else { return }
        let work = job.failures.compactMap { job.retryable[$0.id] }
        job.failures.removeAll { job.retryable[$0.id] != nil }
        job.retryable = [:]
        job.pending.append(contentsOf: work)
        if job.state == .failed { job.state = .running }
        startTicker()
        pump()
    }

    /// Gives up on the failed files and calls the job done.
    public func skipFailures(of job: TransferJob) {
        guard !job.failures.isEmpty else { return }
        discardPartials(of: Array(job.retryable.values), in: job)
        job.skippedFiles += job.failures.count
        job.failures = []
        job.retryable = [:]
        if job.state == .failed {
            job.state = .finished
            onJobsChanged?()
        }
        onCheckpoint?()
    }

    public func remove(_ job: TransferJob) {
        guard job.state.hasEnded, job.running.isEmpty else { return }
        // Nothing will resume the failed files' partial copies now.
        discardPartials(of: Array(job.retryable.values) + job.pending, in: job)
        job.retryable = [:]
        jobs.removeAll { $0 === job }
        onJobsChanged?()
        onCheckpoint?()
    }

    /// Clears finished and cancelled jobs from the list.
    public func removeEnded() {
        jobs.removeAll { ($0.state == .finished || $0.state == .cancelled) && $0.running.isEmpty }
        onJobsChanged?()
    }

    // MARK: - Planning

    private func prepare(_ job: TransferJob) async {
        if job.state == .queued { job.state = .preparing }
        job.isPreparing = true
        startTicker()
        for item in job.items {
            guard job.state != .cancelled else { break }
            await plan(item, to: job.destinationFolder.appending(item.name), in: job, pickedByUser: true)
        }
        job.isPreparing = false
        if job.state == .preparing { job.state = .running }
        pump()
    }

    /// Works out what `item` needs at `destination`: one rename or copy, a file to
    /// stream, or a folder to create (or merge into) and look through.
    /// `throughMac` streams the item whatever the job's route, e.g. a renamed
    /// copy, which a direct route cannot make.
    private func plan(_ given: FileItem, to destination: RemotePath, in job: TransferJob, pickedByUser: Bool = false, throughMac: Bool = false) async {
        var item = given
        var destination = destination
        if item.kind == .other {
            // Something the listing did not resolve, e.g. a link into a privacy-guarded
            // folder. Look at it now if the user picked it, skip it otherwise.
            guard pickedByUser, let resolved = try? await job.source.provider.stat(item.path), resolved.kind != .other else {
                job.skippedFiles += 1
                return
            }
            item = resolved
        }
        let rescan = WorkItem(source: item, destination: destination, action: .scan)
        let sameLocation = job.source.provider.locationID == job.destination.provider.locationID
        if sameLocation, item.isDirectory, item.path.isAncestor(of: destination) {
            fail(item, String(localized: "폴더를 자신의 하위 폴더로 이동하거나 복사할 수 없습니다: \(item.path.string)"), retry: nil, in: job)
            return
        }
        if sameLocation, item.path == destination {
            // Moving an item onto itself does nothing; copying it keeps both, like Finder.
            guard job.kind == .copy else { return }
            do {
                destination = try await freePath(for: destination, isDirectory: item.isDirectory, in: job)
            } catch {
                fail(item, error.localizedDescription, retry: rescan, in: job)
                return
            }
        }
        let existing: FileItem?
        do {
            existing = try await existingItem(at: destination, in: job)
        } catch {
            fail(item, error.localizedDescription, retry: rescan, in: job)
            return
        }
        // On the Mac, one system call per folder would show no progress, not
        // stop when cancelled, and skip the clash questions: folders are gone
        // through file by file, and files bound for another disk are streamed.
        // Within one disk a file is still copied (cloned, on APFS) or renamed whole.
        let localAcrossDisks = job.route == .withinLocation && job.source.provider.isLocal
            && !LocalFileProvider.areOnSameVolume(item.path, destination.parent ?? destination)
        let wholeItem: WorkItem.Action = switch job.route {
        case .withinLocation where localAcrossDisks: .stream
        case .withinLocation where job.kind == .move: .rename
        case .withinLocation where job.source.provider.isLocal && item.isDirectory: .stream
        case .withinLocation: .providerCopy
        case .direct where !throughMac: .direct
        default: .stream
        }

        if job.resumedDone.contains(item.path) {
            // Done before the app quit.
            job.done.insert(item.path)
            job.totalFiles += 1
            job.completedFiles += 1
            let size = item.isDirectory ? 0 : item.size ?? 0
            job.totalBytes += size
            job.completedBytes += size
            job.transferredBytes = job.completedBytes
            return
        }
        guard item.isDirectory else {
            if existing?.isDirectory == true {
                fail(item, String(localized: "같은 이름의 폴더가 이미 있습니다: \(destination.string)"), retry: nil, in: job)
            } else {
                // A clash with an existing file is settled when its turn comes. A file
                // cut off before the app quit picks up its partial copy, which is
                // also why it does not count as a clash with itself.
                var work = WorkItem(source: item, destination: destination, action: wholeItem)
                if job.resumedUnfinished.contains(item.path) {
                    // A source edited since (a growing log, a re-exported video)
                    // starts over; its old beginning is no use.
                    if let version = job.resumedVersions[item.path], !version.matches(item) {
                        Log.transfer.info("\(job.logName): 원본이 바뀌어 처음부터 다시 보냄: \(item.path.string)")
                        await job.destination.provider.discardPartialWrite(to: destination)
                    } else {
                        work.mayHavePartial = true
                    }
                }
                add(work, in: job)
            }
            return
        }
        if let existing {
            guard existing.isDirectory else {
                fail(item, String(localized: "같은 이름의 파일이 이미 있습니다: \(destination.string)"), retry: nil, in: job)
                return
            }
            // Folders merge, like FileZilla; clashes inside are settled file by file.
            await planContents(of: item, into: destination, in: job, throughMac: throughMac)
        } else if wholeItem != .stream {
            add(WorkItem(source: item, destination: destination, action: wholeItem), in: job)
        } else {
            do {
                try await job.destination.provider.makeDirectory(destination)
            } catch {
                fail(item, error.localizedDescription, retry: rescan, in: job)
                return
            }
            remember(FileItem(path: destination, kind: .directory), in: job)
            job.listings[destination] = [:]
            await planContents(of: item, into: destination, in: job, throughMac: throughMac)
        }
    }

    private func planContents(of folder: FileItem, into destination: RemotePath, in job: TransferJob, throughMac: Bool = false) async {
        let children: [FileItem]
        do {
            children = try await job.source.provider.list(folder.path)
        } catch {
            fail(folder, error.localizedDescription, retry: WorkItem(source: folder, destination: destination, action: .scan), in: job)
            return
        }
        if job.kind == .move { job.foldersToClean.append(folder.path) }
        for child in children {
            guard job.state != .cancelled else { return }
            if child.isDirectory, child.isSymbolicLink {
                // Linked folders are not followed: they can loop, or lead far away.
                job.skippedFiles += 1
                continue
            }
            await plan(child, to: destination.appending(child.name), in: job, throughMac: throughMac)
        }
    }

    private func add(_ work: WorkItem, in job: TransferJob) {
        job.pending.append(work)
        job.totalFiles += 1
        if !work.source.isDirectory {
            job.totalBytes += work.source.size ?? 0
        }
        pump()
    }

    /// Takes back what `add` counted for `work`, which is about to be planned
    /// again (and counted again) as the items it turned out to be.
    private func uncount(_ work: WorkItem, in job: TransferJob) {
        job.totalFiles -= 1
        if !work.source.isDirectory {
            job.totalBytes -= work.source.size ?? 0
        }
    }

    private func fail(_ item: FileItem, _ message: String, retry: WorkItem?, in job: TransferJob) {
        let failure = TransferFailure(path: item.path, message: message)
        job.failures.append(failure)
        if let retry { job.retryable[failure.id] = retry }
    }

    /// What is at `path` on the destination, from a listing of its folder taken once per job.
    private func existingItem(at path: RemotePath, in job: TransferJob) async throws -> FileItem? {
        guard let parent = path.parent else { return nil }
        if job.listings[parent] == nil {
            let listing = try await job.destination.provider.list(parent)
            if job.listings[parent] == nil {
                let matching = job.nameMatching
                job.listings[parent] = Dictionary(listing.map { (matching.key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
            }
        }
        return job.listings[parent]?[job.nameMatching.key(path.name)]
    }

    /// A name next to `path` that nothing uses or has claimed, claimed for the caller.
    private func freePath(for path: RemotePath, isDirectory: Bool, in job: TransferJob) async throws -> RemotePath {
        guard let parent = path.parent else { return path }
        _ = try await existingItem(at: path, in: job)
        let matching = job.nameMatching
        let taken = Set(job.listings[parent, default: [:]].keys).union(job.reserved.filter { $0.parent == parent }.map { matching.key($0.name) })
        let free = parent.appending(RemotePath.freeName(for: path.name, isDirectory: isDirectory, taken: taken, key: matching.key))
        job.reserved.insert(free)
        return free
    }

    private func remember(_ item: FileItem, in job: TransferJob) {
        guard let parent = item.path.parent else { return }
        job.listings[parent]?[job.nameMatching.key(item.name)] = item
        job.reserved.remove(item.path)
    }

    // MARK: - Running

    /// Tries after a dropped connection before an item counts as failed.
    static let automaticRetries = 3
    /// The pause before the first of those; each next one waits longer.
    nonisolated(unsafe) static var retryPause: Duration = .seconds(3)

    private enum Outcome {
        case done(bytes: Int64, verified: Bool)
        case skipped(bytes: Int64)
        /// Carries the item as far as it got, for a retry.
        case failed(String, WorkItem)
        /// Stopped by pause or cancel, carrying the item as far as it got.
        case interrupted(WorkItem)
        /// The connection dropped; the item goes again after a pause.
        case retryLater(WorkItem, reason: String)
        case planned
    }

    private func pump() {
        var active = jobs.reduce(0) { $0 + $1.running.count }
        for job in jobs where job.state == .running || job.state == .preparing {
            while active < maxConcurrentTransfers, !job.pending.isEmpty {
                launch(job.pending.removeFirst(), in: job)
                active += 1
            }
            if job.state == .running, !job.isPreparing, job.pending.isEmpty, job.running.isEmpty, job.waitingToRetry == 0 {
                finish(job)
            }
        }
    }

    private func launch(_ work: WorkItem, in job: TransferJob) {
        let id = UUID()
        let counter = ByteCounter()
        // The task cannot start before this method returns: both run on the main actor.
        let task = Task { [self] in
            let outcome = await perform(work, in: job, counter: counter)
            settle(id, outcome, in: job)
        }
        job.running[id] = (work, counter, task)
    }

    private func perform(_ given: WorkItem, in job: TransferJob, counter: ByteCounter) async -> Outcome {
        var work = given
        if work.action == .scan {
            await plan(work.source, to: work.destination, in: job)
            return .planned
        }
        do {
            if work.copied {
                // The copy is in place; trying again means deleting the original.
                try await job.source.provider.delete(work.source.path)
                return .done(bytes: work.source.size ?? 0, verified: false)
            }
            if work.settled == nil, let existing = try await existingItem(at: work.destination, in: job) {
                if work.source.isDirectory, existing.isDirectory {
                    // The folder appeared since planning: merge into it instead.
                    uncount(work, in: job)
                    await plan(work.source, to: work.destination, in: job)
                    return .planned
                }
                guard existing.isDirectory == work.source.isDirectory else {
                    return .failed(existing.isDirectory ? String(localized: "같은 이름의 폴더가 이미 있습니다: \(work.destination.string)") : String(localized: "같은 이름의 파일이 이미 있습니다: \(work.destination.string)"), work)
                }
                let answer = await resolve(TransferConflict(incoming: work.source, existing: existing), in: job)
                work.settled = answer
                if answer == .keepBoth {
                    work.destination = try await freePath(for: work.destination, isDirectory: work.source.isDirectory, in: job)
                }
            }
            if work.settled == .skip {
                return .skipped(bytes: work.source.size ?? 0)
            }
            guard job.state == .running || job.state == .preparing, !Task.isCancelled else {
                return .interrupted(work)
            }
            let source = job.source.provider
            let destination = job.destination.provider
            var resumedFrom: Int64 = 0
            var verified = false
            if work.action == .direct, job.route != .direct || directRoute == nil || work.destination.name != work.source.name {
                // The job fell back to the Mac or the direct route was turned off
                // (the job says so from now on), or this is a renamed copy, which
                // tar on the server cannot make: stream it instead.
                if directRoute == nil { job.route = .viaMac }
                uncount(work, in: job)
                await plan(work.source, to: work.destination, in: job, throughMac: true)
                return .planned
            }
            switch work.action {
            case .stream:
                resumedFrom = await resumableOffset(for: work, in: job)
                do {
                    if resumedFrom > 0, let size = work.source.size {
                        let rest = source.read(work.source.path, range: resumedFrom..<size).counted(by: counter)
                        try await destination.write(work.destination, from: rest, resumingAt: resumedFrom)
                    } else {
                        try await destination.write(work.destination, from: source.read(work.source.path, range: nil).counted(by: counter))
                    }
                } catch {
                    // Whatever reached the destination waits in its partial file,
                    // which exists (perhaps empty) as soon as the write began.
                    work.mayHavePartial = true
                    throw error
                }
                work.mayHavePartial = false
                if job.verifiesChecksums, let (expected, actual) = try await checksums(of: work.source.path, on: source, and: work.destination, on: destination) {
                    guard expected == actual else {
                        // A retry must replace the bad copy, not trip over it as a clash.
                        work.settled = .overwrite
                        return .failed(String(localized: "체크섬이 일치하지 않습니다 (원본 \(expected.prefix(12))…, 대상 \(actual.prefix(12))…)"), work)
                    }
                    verified = true
                }
                if destination.capabilities.contains(.modificationTime), let modified = work.source.modified {
                    try? await destination.setModified(modified, at: work.destination)
                }
            case .rename, .providerCopy:
                // Neither replaces an existing file, so clear the way first.
                if work.settled == .overwrite {
                    try await destination.delete(work.destination)
                }
                if work.action == .rename {
                    try await source.move(work.source.path, to: work.destination)
                } else {
                    try await source.copy(work.source.path, to: work.destination)
                }
            case .direct:
                guard let directRoute, let folder = work.destination.parent else { break }
                do {
                    try await directRoute.send(work.source, source, destination, folder)
                } catch let unavailable as DirectRouteUnavailable {
                    // The source cannot reach the destination: the Mac carries
                    // this item and everything after it.
                    Log.transfer.error("\(job.logName): 서버 간 직접 전송 불가, Mac 경유로 전환: \(unavailable.reason)")
                    job.route = .viaMac
                    uncount(work, in: job)
                    await plan(work.source, to: work.destination, in: job, throughMac: true)
                    return .planned
                }
                if !work.source.isDirectory, job.verifiesChecksums, let (expected, actual) = try await checksums(of: work.source.path, on: source, and: work.destination, on: destination) {
                    guard expected == actual else {
                        work.settled = .overwrite
                        return .failed(String(localized: "체크섬이 일치하지 않습니다 (원본 \(expected.prefix(12))…, 대상 \(actual.prefix(12))…)"), work)
                    }
                    verified = true
                }
            case .scan:
                break
            }
            remember(FileItem(path: work.destination, kind: work.source.kind, size: work.source.size, modified: work.source.modified), in: job)
            if job.kind == .move, work.action == .stream || work.action == .direct {
                do {
                    try await source.delete(work.source.path)
                } catch {
                    work.copied = true
                    return .failed(String(localized: "복사했으나 원본을 삭제할 수 없습니다: \(error.localizedDescription)"), work)
                }
            }
            let bytes = work.action == .stream ? resumedFrom + counter.total : (work.source.size ?? 0)
            return .done(bytes: bytes, verified: verified)
        } catch {
            if job.state == .paused || job.state == .cancelled || error is CancellationError {
                return .interrupted(work)
            }
            // Wi-Fi changing or a server restarting should not fail a long
            // transfer; the partial copy is resumed where it can be.
            if ProviderError.isPassing(error), work.automaticRetries < Self.automaticRetries {
                work.automaticRetries += 1
                return .retryLater(work, reason: error.localizedDescription)
            }
            return .failed(error.localizedDescription, work)
        }
    }

    /// Both sides' SHA-256, or nil when either side has none to give for this
    /// file (a converted Google Doc has none), which leaves it unverified.
    private func checksums(of sent: RemotePath, on source: any FileProvider, and received: RemotePath, on destination: any FileProvider) async throws -> (String, String)? {
        guard source.capabilities.contains(.checksum), destination.capabilities.contains(.checksum) else { return nil }
        do {
            async let expected = source.checksum(sent)
            async let actual = destination.checksum(received)
            return try await (expected, actual)
        } catch ProviderError.unsupported {
            return nil
        }
    }

    /// Where to pick a cut-off file up again. Partial files this job wrote are
    /// trusted; one found from before is resumed only when checksums will be
    /// compared, since it might hold a different file's beginning.
    private func resumableOffset(for work: WorkItem, in job: TransferJob) async -> Int64 {
        let source = job.source.provider
        let destination = job.destination.provider
        guard destination.capabilities.contains(.resumableWrite), source.capabilities.contains(.rangeRead),
              let size = work.source.size, size > 0
        else { return 0 }
        let partial = work.destination.partialWritePath
        let written: Int64?
        if work.mayHavePartial {
            written = try? await destination.stat(partial).size
        } else if job.verifiesChecksums, source.capabilities.contains(.checksum), destination.capabilities.contains(.checksum) {
            written = job.listings[partial.parent ?? .root]?[job.nameMatching.key(partial.name)]?.size
        } else {
            written = nil
        }
        guard let written, written > 0, written < size else { return 0 }
        return written
    }

    private func discardPartials(of work: [WorkItem], in job: TransferJob) {
        let destination = job.destination.provider
        for item in work where item.mayHavePartial {
            Task { await destination.discardPartialWrite(to: item.destination) }
        }
    }

    private func resolve(_ conflict: TransferConflict, in job: TransferJob) async -> ConflictAnswer {
        if let remembered = job.rememberedAnswer { return remembered }
        switch job.policy {
        case .overwrite:
            return .overwrite
        case .skip:
            return .skip
        case .overwriteIfNewer:
            guard let incoming = conflict.incoming.modified, let existing = conflict.existing.modified else { return .skip }
            return incoming > existing ? .overwrite : .skip
        case .ask:
            return await withCheckedContinuation { job.questions.append(.init(conflict: conflict, answer: $0)) }
        }
    }

    private func settle(_ id: UUID, _ outcome: Outcome, in job: TransferJob) {
        guard let running = job.running.removeValue(forKey: id) else { return }
        switch outcome {
        case .done(let bytes, let verified):
            job.completedFiles += 1
            job.completedBytes += bytes
            if verified { job.verifiedFiles += 1 }
            job.done.insert(running.work.source.path)
        case .skipped(let bytes):
            job.skippedFiles += 1
            job.skippedBytes += bytes
            job.done.insert(running.work.source.path)
        case .failed(let message, let work):
            Log.transfer.error("\(job.logName): \(running.work.source.path) 실패: \(message)")
            let failure = TransferFailure(path: running.work.source.path, message: message)
            job.failures.append(failure)
            job.retryable[failure.id] = work
        case .interrupted(let work):
            if job.state == .cancelled {
                discardPartials(of: [work], in: job)
            } else {
                job.pending.insert(work, at: 0)
            }
        case .retryLater(let work, let reason):
            Log.transfer.info("\(job.logName): \(work.source.path) 연결 문제로 \(work.automaticRetries)번째 다시 시도 예정: \(reason)")
            job.waitingToRetry += 1
            Task { [self] in
                try? await Task.sleep(for: Self.retryPause * work.automaticRetries)
                job.waitingToRetry -= 1
                if job.state == .cancelled {
                    discardPartials(of: [work], in: job)
                } else {
                    job.pending.insert(work, at: 0)
                }
                pump()
            }
        case .planned:
            break
        }
        job.transferredBytes = job.completedBytes + job.inFlightBytes
        if job.state == .cancelled, job.running.isEmpty {
            onJobsChanged?()
        }
        pump()
        onCheckpoint?()
    }

    private func finish(_ job: TransferJob) {
        guard !job.isFinishing else { return }
        job.isFinishing = true
        Task { [self] in
            if job.kind == .move {
                await removeEmptiedFolders(of: job)
            }
            job.isFinishing = false
            // A retry may have come in meanwhile.
            guard job.state == .running, job.pending.isEmpty, job.running.isEmpty, !job.isPreparing else {
                pump()
                return
            }
            job.state = job.failures.isEmpty ? .finished : .failed
            job.bytesPerSecond = 0
            job.transferredBytes = job.completedBytes
            Log.transfer.info("\(job.logName): \(job.state == .finished ? String(localized: "완료") : String(localized: "실패 \(job.failures.count)개")) (파일 \(job.completedFiles)개, 건너뜀 \(job.skippedFiles)개, \(job.completedBytes) B)")
            onJobsChanged?()
            onCheckpoint?()
        }
    }

    /// Removes source folders a move left empty, deepest first. Folders that
    /// still hold something (skipped or failed files) stay.
    private func removeEmptiedFolders(of job: TransferJob) async {
        let folders = Set(job.foldersToClean).sorted { $0.components.count > $1.components.count }
        for folder in folders {
            guard let children = try? await job.source.provider.list(folder), children.isEmpty else { continue }
            if (try? await job.source.provider.delete(folder)) != nil {
                job.foldersToClean.removeAll { $0 == folder }
            }
        }
    }

    // MARK: - Progress

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [self] in
            while jobs.contains(where: { $0.state == .running || $0.state == .preparing }) {
                try? await Task.sleep(for: .milliseconds(500))
                sample()
            }
            ticker = nil
        }
    }

    private func sample() {
        let now = ContinuousClock.now
        for job in jobs where job.state == .running || job.state == .preparing {
            let bytes = job.completedBytes + job.inFlightBytes
            job.transferredBytes = bytes
            if let last = job.lastSample {
                let elapsed = (now - last.at).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                if seconds > 0 {
                    let rate = Double(bytes - last.bytes) / seconds
                    job.bytesPerSecond = job.bytesPerSecond == 0 ? rate : job.bytesPerSecond * 0.6 + rate * 0.4
                }
            }
            job.lastSample = (bytes, now)
        }
    }
}
