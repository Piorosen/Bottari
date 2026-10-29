import BottariCore
import Foundation
import Synchronization

/// One side of a transfer: where the files are, and what to call that place.
public struct TransferEndpoint: Sendable {
    public let provider: any FileProvider
    public let name: String
    /// How the app finds this place again after a restart, e.g. a saved
    /// site's ID. Without it on both sides a job is not saved for later.
    public let place: String?

    public init(_ provider: any FileProvider, name: String? = nil, place: String? = nil) {
        self.provider = provider
        self.name = name ?? provider.displayName
        self.place = place
    }
}

/// A job as far as it got, saved so it can carry on after the app restarts.
public struct TransferRecord: Codable, Identifiable, Hashable, Sendable {
    public struct Place: Codable, Hashable, Sendable {
        /// `TransferEndpoint.place`.
        public var place: String
        public var name: String

        public init(place: String, name: String) {
            self.place = place
            self.name = name
        }
    }

    public var id: UUID
    public var kind: TransferKind
    /// The files and folders the user picked.
    public var items: [RemotePath]
    public var source: Place
    public var destination: Place
    public var folder: RemotePath
    public var policy: ConflictPolicy
    public var verifiesChecksums: Bool
    /// Source files already transferred or skipped; a resumed job leaves them be.
    public var done: [RemotePath]
    /// Source files cut off midway, whose partial copies a resumed job continues.
    public var unfinished: [RemotePath]
    public var totalFiles: Int
    public var totalBytes: Int64
    public var transferredBytes: Int64
    public var savedAt: Date

    public init(
        id: UUID,
        kind: TransferKind,
        items: [RemotePath],
        source: Place,
        destination: Place,
        folder: RemotePath,
        policy: ConflictPolicy,
        verifiesChecksums: Bool,
        done: [RemotePath],
        unfinished: [RemotePath],
        totalFiles: Int,
        totalBytes: Int64,
        transferredBytes: Int64,
        savedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.items = items
        self.source = source
        self.destination = destination
        self.folder = folder
        self.policy = policy
        self.verifiesChecksums = verifiesChecksums
        self.done = done
        self.unfinished = unfinished
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.savedAt = savedAt
    }

    public var name: String {
        guard let first = items.first else { return "" }
        return items.count == 1 ? first.name : String(localized: "\(first.name) 외 \(items.count - 1)개")
    }
}

public enum TransferKind: String, Codable, Sendable {
    case copy
    /// Copy, then remove the originals.
    case move
}

/// What to do when the destination already has a file with the same name.
public enum ConflictPolicy: String, CaseIterable, Codable, Sendable {
    case ask
    /// Replace it only if the incoming file was modified later.
    case overwriteIfNewer
    case overwrite
    case skip
}

/// The user's answer to one conflict.
public enum ConflictAnswer: Sendable {
    case overwrite
    case skip
    /// Keep the existing file and give the incoming one a free name, like Finder's "name 2.txt".
    case keepBoth
}

/// How the bytes travel.
public enum TransferRoute: Sendable {
    /// Inside one location, by rename or the provider's own copy; nothing goes through the Mac.
    case withinLocation
    case upload
    case download
    /// Between two remote locations, streamed through the Mac.
    case viaMac
    /// Between folders on the Mac, streamed.
    case local
}

/// A file that already exists where an incoming one is going.
public struct TransferConflict: Identifiable, Sendable {
    public let id = UUID()
    public let incoming: FileItem
    public let existing: FileItem
}

public struct TransferFailure: Identifiable, Sendable {
    public let id = UUID()
    /// The source item that could not be transferred.
    public let path: RemotePath
    public let message: String
}

/// One step of a job: a file to stream, an item to rename or copy within its
/// location, or a folder still to look through.
struct WorkItem: Sendable {
    enum Action: Sendable {
        case stream, rename, providerCopy
        /// Plan `source` again, e.g. retrying a folder that could not be listed.
        case scan
    }

    var source: FileItem
    var destination: RemotePath
    var action: Action
    /// Set once the user (or the policy) has settled a name clash for this item,
    /// so a paused item does not ask again.
    var settled: ConflictAnswer?
    /// An earlier attempt in this job wrote part of the file, which may be resumed.
    var mayHavePartial = false
}

/// Bytes streamed so far by one transfer, written by the stream and read by the
/// queue's progress ticker.
final class ByteCounter: Sendable {
    private let bytes = Mutex<Int64>(0)

    func add(_ count: Int) {
        bytes.withLock { $0 += Int64(count) }
    }

    var total: Int64 {
        bytes.withLock { $0 }
    }
}

extension AsyncThrowingStream where Element == Data, Failure == any Error {
    /// The same bytes, counted as the consumer takes them.
    func counted(by counter: ByteCounter) -> AsyncThrowingStream<Data, any Error> {
        let source = IteratorBox(makeAsyncIterator())
        return AsyncThrowingStream(unfolding: {
            let chunk = try await source.next()
            if let chunk { counter.add(chunk.count) }
            return chunk
        })
    }
}

/// The stream asks for elements from one task at a time, which makes sharing
/// the iterator safe.
private final class IteratorBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, any Error>.Iterator

    init(_ iterator: AsyncThrowingStream<Data, any Error>.Iterator) {
        self.iterator = iterator
    }

    func next() async throws -> Data? {
        try await iterator.next()
    }
}
