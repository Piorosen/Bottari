import BottariCore
import Foundation
import Synchronization

/// Files kept in memory, with knobs for failures and slow streams.
final class MemoryFileProvider: FileProvider {
    struct Entry {
        var data = Data()
        var modified = Date(timeIntervalSince1970: 1_700_000_000)
        var isDirectory = false
        var isLink = false
    }

    struct State {
        var entries: [RemotePath: Entry] = [.root: Entry(isDirectory: true)]
        /// Names whose writes fail partway.
        var failingWrites: Set<String> = []
        var chunkSize = 4096
        var chunkDelay: Duration?
        var writesInProgress = 0
        var mostWritesAtOnce = 0
    }

    let displayName: String
    let locationID: String
    let capabilities: ProviderCapabilities = [.rangeRead]
    let home = RemotePath.root
    let state = Mutex(State())

    init(_ name: String) {
        displayName = name
        locationID = "memory://\(name)"
    }

    // MARK: - Setting up and checking

    func addFile(_ path: RemotePath, _ text: String, modified: Date? = nil) {
        addFile(path, Data(text.utf8), modified: modified)
    }

    func addFile(_ path: RemotePath, _ data: Data, modified: Date? = nil) {
        state.withLock { state in
            for folder in path.lineage.dropLast() where state.entries[folder] == nil {
                state.entries[folder] = Entry(isDirectory: true)
            }
            var entry = Entry(data: data)
            if let modified { entry.modified = modified }
            state.entries[path] = entry
        }
    }

    func addFolder(_ path: RemotePath, isLink: Bool = false) {
        state.withLock { state in
            for folder in path.lineage where state.entries[folder] == nil {
                state.entries[folder] = Entry(isDirectory: true)
            }
            state.entries[path]?.isLink = isLink
        }
    }

    func text(_ path: RemotePath) -> String? {
        state.withLock { $0.entries[path].flatMap { $0.isDirectory ? nil : String(decoding: $0.data, as: UTF8.self) } }
    }

    func data(_ path: RemotePath) -> Data? {
        state.withLock { $0.entries[path]?.data }
    }

    func exists(_ path: RemotePath) -> Bool {
        state.withLock { $0.entries[path] != nil }
    }

    /// Every path below the root, sorted, folders marked with a trailing slash.
    var tree: [String] {
        state.withLock { state in
            state.entries.filter { !$0.key.isRoot }.map { $0.key.string + ($0.value.isDirectory ? "/" : "") }.sorted()
        }
    }

    // MARK: - FileProvider

    private func item(_ path: RemotePath, _ entry: Entry) -> FileItem {
        FileItem(
            path: path,
            kind: entry.isDirectory ? .directory : .file,
            isSymbolicLink: entry.isLink,
            size: entry.isDirectory ? nil : Int64(entry.data.count),
            modified: entry.modified
        )
    }

    func list(_ path: RemotePath) async throws -> [FileItem] {
        try state.withLock { state in
            guard let folder = state.entries[path] else { throw ProviderError.notFound(path) }
            guard folder.isDirectory else { throw ProviderError.notADirectory(path) }
            return state.entries.filter { $0.key.parent == path }.map { item($0.key, $0.value) }.sorted(by: FileItem.finderOrder)
        }
    }

    func stat(_ path: RemotePath) async throws -> FileItem {
        try state.withLock { state in
            guard let entry = state.entries[path] else { throw ProviderError.notFound(path) }
            return item(path, entry)
        }
    }

    func read(_ path: RemotePath, range: Range<Int64>?) -> AsyncThrowingStream<Data, any Error> {
        let offset = Mutex(Int(range?.lowerBound ?? 0))
        return AsyncThrowingStream(unfolding: { [self] in
            let (data, size, delay) = try self.state.withLock { state in
                guard let entry = state.entries[path] else { throw ProviderError.notFound(path) }
                guard !entry.isDirectory else { throw ProviderError.isADirectory(path) }
                return (entry.data, state.chunkSize, state.chunkDelay)
            }
            if let delay { try await Task.sleep(for: delay) }
            try Task.checkCancellation()
            let end = min(data.count, Int(range?.upperBound ?? Int64(data.count)))
            return offset.withLock { start -> Data? in
                guard start < end else { return nil }
                let chunk = data.subdata(in: start..<min(end, start + size))
                start += chunk.count
                return chunk
            }
        })
    }

    func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws {
        let fails = try state.withLock { state in
            guard let parent = path.parent, state.entries[parent]?.isDirectory == true else { throw ProviderError.notFound(path) }
            if state.entries[path]?.isDirectory == true { throw ProviderError.isADirectory(path) }
            state.writesInProgress += 1
            state.mostWritesAtOnce = max(state.mostWritesAtOnce, state.writesInProgress)
            return state.failingWrites.contains(path.name)
        }
        defer { state.withLock { $0.writesInProgress -= 1 } }
        // Collect everything first and commit at the end, like an atomic write.
        var received = Data()
        for try await chunk in data {
            received.append(chunk)
            if fails { throw ProviderError.io("디스크가 가득 찼어요") }
        }
        state.withLock { $0.entries[path] = Entry(data: received, modified: Date()) }
    }

    func makeDirectory(_ path: RemotePath) async throws {
        try state.withLock { state in
            guard let parent = path.parent, state.entries[parent]?.isDirectory == true else { throw ProviderError.notFound(path) }
            guard state.entries[path] == nil else { throw ProviderError.alreadyExists(path) }
            state.entries[path] = Entry(isDirectory: true)
        }
    }

    func move(_ from: RemotePath, to: RemotePath) async throws {
        try state.withLock { state in
            guard state.entries[from] != nil else { throw ProviderError.notFound(from) }
            guard state.entries[to] == nil else { throw ProviderError.alreadyExists(to) }
            for (path, entry) in state.entries where path == from || from.isAncestor(of: path) {
                state.entries[path] = nil
                state.entries[RemotePath(to.string + "/" + path.components.dropFirst(from.components.count).joined(separator: "/"))] = entry
            }
        }
    }

    func delete(_ path: RemotePath) async throws {
        try state.withLock { state in
            guard state.entries[path] != nil else { throw ProviderError.notFound(path) }
            for key in state.entries.keys where key == path || path.isAncestor(of: key) {
                state.entries[key] = nil
            }
        }
    }
}
