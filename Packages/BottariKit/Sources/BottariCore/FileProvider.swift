import Foundation

/// What a provider can do beyond the basics every provider supports.
public struct ProviderCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Reads an arbitrary byte range without fetching the whole file
    /// (thumbnails, video seeking, resuming a transfer).
    public static let rangeRead = ProviderCapabilities(rawValue: 1 << 0)
    /// Runs shell commands on the host, e.g. over SSH.
    public static let exec = ProviderCapabilities(rawValue: 1 << 1)
    /// Copies within itself without moving bytes through the Mac.
    public static let serverSideCopy = ProviderCapabilities(rawValue: 1 << 2)
    /// Has a trash that `trash(_:)` moves items into.
    public static let trash = ProviderCapabilities(rawValue: 1 << 3)
}

/// One place files live: the Mac, an SFTP server, a cloud drive.
///
/// Panes only ever talk to this protocol, so "server to server" is just one
/// provider's `read` stream fed into another provider's `write`.
public protocol FileProvider: Sendable {
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    /// Where a new pane opened on this provider starts.
    var home: RemotePath { get }

    /// Entries of the directory at `path`, in Finder order.
    func list(_ path: RemotePath) async throws -> [FileItem]
    func stat(_ path: RemotePath) async throws -> FileItem
    /// Streams the file's bytes, or only `range` of them when given.
    func read(_ path: RemotePath, range: Range<Int64>?) -> AsyncThrowingStream<Data, any Error>
    /// Writes the streamed bytes to `path`. If anything fails, an existing file
    /// at `path` must be left untouched.
    func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws
    func makeDirectory(_ path: RemotePath) async throws
    /// Renames or moves an item. Fails with `.alreadyExists` instead of overwriting.
    func move(_ from: RemotePath, to: RemotePath) async throws
    /// Copies an item, recursively for directories. Requires `.serverSideCopy`.
    func copy(_ from: RemotePath, to: RemotePath) async throws
    /// Removes an item permanently, recursively for directories.
    func delete(_ path: RemotePath) async throws
    /// Moves an item to the provider's trash. Requires `.trash`.
    func trash(_ path: RemotePath) async throws
}

extension FileProvider {
    public func copy(_ from: RemotePath, to: RemotePath) async throws {
        throw ProviderError.unsupported("서버 안에서 복사")
    }

    public func trash(_ path: RemotePath) async throws {
        throw ProviderError.unsupported("휴지통")
    }

    /// Reads a whole file, or a range of it, into memory. Meant for small files
    /// such as text previews; transfers should stream with `read(_:range:)`.
    public func readData(_ path: RemotePath, range: Range<Int64>? = nil) async throws -> Data {
        var out = Data()
        for try await chunk in read(path, range: range) {
            out.append(chunk)
        }
        return out
    }

    public func write(_ path: RemotePath, data: Data) async throws {
        try await write(path, from: AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        })
    }
}
