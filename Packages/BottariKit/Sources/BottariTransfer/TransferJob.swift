import BottariCore
import Foundation
import Observation

/// One copy or move the user asked for: some items from one place into a
/// folder somewhere else. Folders are expanded into their files, which the
/// queue then transfers a few at a time.
@MainActor
@Observable
public final class TransferJob: Identifiable {
    public enum State: Equatable, Sendable {
        case queued
        /// Looking through folders and creating them at the destination.
        case preparing
        case running
        case paused
        case finished
        /// Done with everything it could do; `failures` lists the rest.
        case failed
        case cancelled

        public var hasEnded: Bool { self == .finished || self == .failed || self == .cancelled }
    }

    public nonisolated let id = UUID()
    public let kind: TransferKind
    public let source: TransferEndpoint
    public let destination: TransferEndpoint
    public let items: [FileItem]
    public let destinationFolder: RemotePath
    public let route: TransferRoute

    public internal(set) var state: State = .queued
    public internal(set) var totalBytes: Int64 = 0
    /// Bytes actually moved so far, including files still in flight.
    public internal(set) var transferredBytes: Int64 = 0
    public internal(set) var totalFiles = 0
    public internal(set) var completedFiles = 0
    public internal(set) var skippedFiles = 0
    /// Files whose checksums were compared after the transfer, and matched.
    public internal(set) var verifiedFiles = 0
    public internal(set) var failures: [TransferFailure] = []
    public internal(set) var bytesPerSecond: Double = 0
    var questions: [Question] = []

    /// The name clash waiting for the user's answer, if any.
    public var pendingConflict: TransferConflict? { questions.first?.conflict }

    public var name: String {
        guard let first = items.first else { return "" }
        return items.count == 1 ? first.name : "\(first.name) 외 \(items.count - 1)개"
    }

    public var fractionCompleted: Double {
        if state == .finished { return 1 }
        if totalBytes > 0 {
            return min(1, Double(transferredBytes + skippedBytes) / Double(totalBytes))
        }
        guard totalFiles > 0 else { return 0 }
        return Double(completedFiles + skippedFiles) / Double(totalFiles)
    }

    public var secondsRemaining: Double? {
        guard state == .running, bytesPerSecond > 0, totalBytes > 0 else { return nil }
        return Double(max(0, totalBytes - transferredBytes - skippedBytes)) / bytesPerSecond
    }

    // Bookkeeping for the queue.
    @ObservationIgnored var policy: ConflictPolicy
    @ObservationIgnored public internal(set) var verifiesChecksums = false
    @ObservationIgnored var rememberedAnswer: ConflictAnswer?
    @ObservationIgnored var pending: [WorkItem] = []
    @ObservationIgnored var running: [UUID: (work: WorkItem, counter: ByteCounter, task: Task<Void, Never>)] = [:]
    @ObservationIgnored var retryable: [UUID: WorkItem] = [:]
    /// Destination folder listings, by folder, so each folder is listed once.
    @ObservationIgnored var listings: [RemotePath: [String: FileItem]] = [:]
    /// Free names handed out for "keep both" that are not written yet.
    @ObservationIgnored var reserved: Set<RemotePath> = []
    /// Source folders a move emptied, to remove at the end.
    @ObservationIgnored var foldersToClean: [RemotePath] = []
    @ObservationIgnored var isPreparing = false
    @ObservationIgnored var isFinishing = false
    @ObservationIgnored var completedBytes: Int64 = 0
    @ObservationIgnored var skippedBytes: Int64 = 0
    @ObservationIgnored var lastSample: (bytes: Int64, at: ContinuousClock.Instant)?

    struct Question {
        let conflict: TransferConflict
        let answer: CheckedContinuation<ConflictAnswer, Never>
    }

    init(
        kind: TransferKind,
        items: [FileItem],
        source: TransferEndpoint,
        destination: TransferEndpoint,
        folder: RemotePath,
        route: TransferRoute,
        policy: ConflictPolicy
    ) {
        self.kind = kind
        self.items = items
        self.source = source
        self.destination = destination
        self.destinationFolder = folder
        self.route = route
        self.policy = policy
    }

    var inFlightBytes: Int64 {
        running.values.reduce(0) { $0 + $1.counter.total }
    }
}
