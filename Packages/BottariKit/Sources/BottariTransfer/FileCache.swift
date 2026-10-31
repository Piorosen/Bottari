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
    /// A download and the callers waiting for it; the last one to give up stops it.
    private struct Download {
        let id = UUID()
        let task: Task<URL, any Error>
        var waiters: Set<UUID> = []
    }

    private var inFlight: [String: Download] = [:]

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
        if inFlight[key] == nil {
            let task = Task { [directory] in
                try await Self.download(item, from: provider, to: target, scratch: directory, progress: progress)
            }
            inFlight[key] = Download(task: task)
        }
        let download = inFlight[key]!
        let waiter = UUID()
        inFlight[key]?.waiters.insert(waiter)
        defer { finished(download.id, key: key) }
        let url = try await withTaskCancellationHandler {
            try await download.task.value
        } onCancel: {
            Task { await self.giveUp(waiter, key: key) }
        }
        prune(keeping: key)
        return url
    }

    /// A caller stopped waiting (Esc on a preview); with nobody left, the download stops.
    private func giveUp(_ waiter: UUID, key: String) {
        guard var download = inFlight[key], download.waiters.remove(waiter) != nil else { return }
        if download.waiters.isEmpty {
            download.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = download
        }
    }

    /// The download ended one way or another; the next caller finds the file or starts again.
    private func finished(_ id: UUID, key: String) {
        if inFlight[key]?.id == id { inFlight[key] = nil }
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
            // A cancelled read just ends; what arrived is not the whole file.
            try Task.checkCancellation()
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
