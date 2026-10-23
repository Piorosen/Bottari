import BottariCore
import CryptoKit
import Foundation

/// Local copies of remote files for previews, viewers and editors.
///
/// A copy is keyed by location, path, modification time and size, so a file
/// that changed on the server is fetched again. The oldest copies are dropped
/// once the cache grows past its limit.
public actor FileCache {
    public let directory: URL
    public let limit: Int64
    private var inFlight: [String: Task<URL, any Error>] = [:]

    public init(directory: URL, limit: Int64 = 2 << 30) {
        self.directory = directory
        self.limit = limit
    }

    /// A local file with `item`'s contents. Files on the Mac are returned as they
    /// are; others are downloaded once. `progress` gets the bytes received so far.
    public func localURL(
        for item: FileItem,
        from provider: any FileProvider,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> URL {
        if provider.isLocal { return URL(fileURLWithPath: item.path.string) }
        let key = Self.key(for: item, at: provider.locationID)
        let target = directory.appending(path: key).appending(path: item.name)
        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber,
           item.size == nil || size.int64Value == item.size {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return target
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let task = Task { [directory] in
            try await Self.download(item, from: provider, to: target, scratch: directory, progress: progress)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let url = try await task.value
        prune(keeping: key)
        return url
    }

    /// Drops every copy, e.g. from settings.
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Bytes the cache currently takes up.
    public func size() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    static func key(for item: FileItem, at location: String) -> String {
        let identity = [location, item.path.string, item.modified.map { String($0.timeIntervalSince1970) } ?? "", item.size.map(String.init) ?? ""]
            .joined(separator: "\u{0}")
        return SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func download(
        _ item: FileItem,
        from provider: any FileProvider,
        to target: URL,
        scratch: URL,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = scratch.appending(path: ".download-\(UUID().uuidString)")
        fm.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        do {
            var received: Int64 = 0
            for try await chunk in provider.read(item.path, range: nil) {
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
                progress?(received)
            }
            try handle.close()
            try? fm.removeItem(at: target)
            try fm.moveItem(at: temp, to: target)
            return target
        } catch {
            try? handle.close()
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private struct Entry {
        let folder: URL
        let size: Int64
        let used: Date
    }

    private func entries() -> [Entry] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            guard let file = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first,
                  let attributes = try? fm.attributesOfItem(atPath: file.path)
            else { return nil }
            return Entry(
                folder: folder,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                used: attributes[.modificationDate] as? Date ?? .distantPast
            )
        }
    }

    /// Removes the least recently used copies until the cache fits its limit.
    private func prune(keeping key: String) {
        var entries = entries().sorted { $0.used < $1.used }
        var total = entries.reduce(0) { $0 + $1.size }
        while total > limit, let oldest = entries.first {
            entries.removeFirst()
            guard oldest.folder.lastPathComponent != key else { continue }
            try? FileManager.default.removeItem(at: oldest.folder)
            total -= oldest.size
        }
    }
}
