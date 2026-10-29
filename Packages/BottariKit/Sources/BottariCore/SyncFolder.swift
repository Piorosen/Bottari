import Foundation

/// Lists shared between Macs through a folder they all see, such as
/// `iCloud Drive/Bottari`. Each list is a plain JSON file there, readable in
/// Finder; the state this Mac last agreed on is kept beside the app, so
/// `ThreeWaySync` can tell which side changed what.
///
/// A file missing from the shared folder (the first sync, or deleted by hand)
/// is written again from this Mac. One that cannot be read is left alone and
/// the error thrown, so a bad edit never wipes the other Macs' lists.
public struct SyncFolder: Sendable {
    public let folder: URL
    /// Where this Mac keeps the last agreed state of each file.
    public let baseFolder: URL

    public init(folder: URL, baseFolder: URL) {
        self.folder = folder
        self.baseFolder = baseFolder
    }

    public struct Outcome<Item: Identifiable> {
        /// What this Mac should now have.
        public let items: [Item]
        public let conflicts: [ThreeWaySync.Conflict<Item>]
    }

    public struct Unreadable: LocalizedError {
        public let name: String
        public let reason: String

        public var errorDescription: String? { String(localized: "\(name)을(를) 읽을 수 없습니다: \(reason)") }
    }

    // MARK: - Lists

    /// Merges `local` with the list in `name` and writes back what changed.
    public func sync<Item: Codable & Identifiable & Equatable>(_ name: String, local: [Item]) throws -> Outcome<Item> {
        try merge(
            local: local,
            remote: read([Item].self, at: folder.appending(path: name), name: name),
            baseName: name,
            writeRemote: { try write($0, to: folder.appending(path: name)) }
        )
    }

    /// Merges a single value, such as the keymap, kept in `name` as one object.
    public func sync<Value: Codable & Equatable>(_ name: String, value: Value) throws -> (value: Value, conflict: (local: Value, remote: Value)?) {
        let remote = try read(Value.self, at: folder.appending(path: name), name: name)
        let outcome = try merge(
            local: [Single(value: value)],
            remote: remote.map { [Single(value: $0)] },
            baseName: name,
            writeRemote: { try write($0[0].value, to: folder.appending(path: name)) }
        )
        let conflict = outcome.conflicts.first.flatMap { c in c.local.flatMap { l in c.remote.map { (l.value, $0.value) } } }
        return (outcome.items.first?.value ?? value, conflict)
    }

    /// Merges items kept one file each in the folder `name`, such as themes,
    /// so a file can be dropped in or taken out by hand.
    public func sync<Item: Codable & Identifiable & Equatable>(directory name: String, local: [Item]) throws -> Outcome<Item> where Item.ID == String {
        let directory = folder.appending(path: name, directoryHint: .isDirectory)
        var files: [String: URL] = [:]
        var remote: [Item]?
        if FileManager.default.fileExists(atPath: directory.path) {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            remote = try urls.compactMap { url in
                guard let item = try read(Item.self, at: url, name: "\(name)/\(url.lastPathComponent)") else { return nil }
                files[item.id] = url
                return item
            }
        }
        return try merge(local: local, remote: remote, baseName: "\(name).json") { items in
            let previous = Dictionary((remote ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for item in items where previous[item.id] != item {
                let url = files[item.id] ?? directory.appending(path: item.id.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".json")
                try write(item, to: url)
            }
            let kept = Set(items.map(\.id))
            for (id, url) in files where !kept.contains(id) {
                try coordinated(writing: url, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
            }
        }
    }

    // MARK: - Agreed state

    /// The state this Mac last agreed on for `name`. Resolving a conflict
    /// changes it, so the next sync settles the item the chosen way.
    public func base<Item: Decodable>(_ name: String, as type: [Item].Type = [Item].self) -> [Item] {
        (try? read(type, at: baseFolder.appending(path: name), name: name)) ?? []
    }

    public func setBase<Item: Encodable>(_ name: String, _ items: [Item]) throws {
        try write(items, to: baseFolder.appending(path: name))
    }

    /// For values synced with `sync(_:value:)`.
    public func setBase<Value: Codable & Equatable>(_ name: String, value: Value) throws {
        try write([Single(value: value)], to: baseFolder.appending(path: name))
    }

    // MARK: -

    private func merge<Item: Codable & Identifiable & Equatable>(
        local: [Item],
        remote: [Item]?,
        baseName: String,
        writeRemote: ([Item]) throws -> Void
    ) throws -> Outcome<Item> {
        let baseFile = baseFolder.appending(path: baseName)
        guard let remote else {
            try writeRemote(local)
            try write(local, to: baseFile)
            return Outcome(items: local, conflicts: [])
        }
        let base = (try? read([Item].self, at: baseFile, name: baseName)) ?? []
        let result = ThreeWaySync.merge(base: base, local: local, remote: remote)
        if result.remote != remote { try writeRemote(result.remote) }
        if result.base != base { try write(result.base, to: baseFile) }
        return Outcome(items: result.merged, conflicts: result.conflicts)
    }

    /// Nil when there is no such file.
    private func read<T: Decodable>(_ type: T.Type, at url: URL, name: String) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try coordinated(reading: url) { try Data(contentsOf: $0) }
        } catch {
            throw Unreadable(name: name, reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder.sync.decode(type, from: data)
        } catch {
            throw Unreadable(name: name, reason: String(localized: "JSON 형식 오류"))
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.sync.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinated(writing: url, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
    }

    /// Through a file coordinator, so iCloud Drive downloads a file before it
    /// is read and does not upload half a write.
    private func coordinated<T>(reading url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    private func coordinated(writing url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var result: Result<Void, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        try result!.get()
    }
}

extension SyncFolder.Outcome: Sendable where Item: Sendable {}

/// A lone value, as the one item of a list.
private struct Single<Value: Codable & Equatable>: Codable, Identifiable, Equatable {
    var id: Int { 0 }
    var value: Value
}

private extension JSONEncoder {
    static var sync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var sync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
