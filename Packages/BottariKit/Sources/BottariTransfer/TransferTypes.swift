import BottariCore
import Foundation
import Synchronization

/// One side of a transfer: where the files are, and what to call that place.
public struct TransferEndpoint: Sendable {
    public let provider: any FileProvider
    public let name: String

    public init(_ provider: any FileProvider, name: String? = nil) {
        self.provider = provider
        self.name = name ?? provider.displayName
    }
}

public enum TransferKind: Sendable {
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
