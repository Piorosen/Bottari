import Foundation

/// The Mac's own disk. A `RemotePath` is simply the absolute file path.
public struct LocalFileProvider: FileProvider {
    public let displayName: String
    public let home: RemotePath
    public let privacy: PrivacyGuard

    static let chunkSize = 256 * 1024

    public init(displayName: String = "이 Mac", home: RemotePath = RemotePath(NSHomeDirectory()), privacy: PrivacyGuard = PrivacyGuard()) {
        self.displayName = displayName
        self.home = home
        self.privacy = privacy
    }

    public var capabilities: ProviderCapabilities { [.rangeRead, .serverSideCopy, .trash] }

    public func list(_ path: RemotePath) async throws -> [FileItem] {
        try requireDirectory(path)
        return try mapErrors(path) {
            try FileManager.default.contentsOfDirectory(atPath: path.string)
                .map { try item(at: path.appending($0), followingGuardedLinks: false) }
                .sorted(by: FileItem.finderOrder)
        }
    }

    /// Follows a link even into a guarded folder: the user asked for this one item.
    public func stat(_ path: RemotePath) async throws -> FileItem {
        try mapErrors(path) { try item(at: path, followingGuardedLinks: true) }
    }

    public func read(_ path: RemotePath, range: Range<Int64>?) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try requireFile(path)
                    let handle = try mapErrors(path) { try FileHandle(forReadingFrom: url(path)) }
                    defer { try? handle.close() }
                    var offset = range?.lowerBound ?? 0
                    let end = range?.upperBound ?? .max
                    try handle.seek(toOffset: UInt64(offset))
                    while offset < end {
                        try Task.checkCancellation()
                        let count = Int(min(Int64(Self.chunkSize), end - offset))
                        guard let data = try handle.read(upToCount: count), !data.isEmpty else { break }
                        continuation.yield(data)
                        offset += Int64(data.count)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws {
        guard let parent = path.parent else { throw ProviderError.permissionDenied(path) }
        try requireDirectory(parent)
        let fm = FileManager.default
        // Write next to the destination and swap it in at the end, so a failed
        // transfer never leaves a half-written file where the original was.
        let temp = parent.appending(".\(path.name).bottari-part")
        do {
            try mapErrors(parent) { try Data().write(to: url(temp)) }
            let handle = try FileHandle(forWritingTo: url(temp))
            do {
                for try await chunk in data {
                    try handle.write(contentsOf: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if let existing = try? fm.attributesOfItem(atPath: path.string),
               let mode = existing[.posixPermissions] {
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.string)
            }
            guard rename(temp.string, path.string) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(atPath: temp.string)
            throw Self.translate(error, path)
        }
    }

    public func makeDirectory(_ path: RemotePath) async throws {
        try mapErrors(path) {
            try FileManager.default.createDirectory(atPath: path.string, withIntermediateDirectories: false)
        }
    }

    public func move(_ from: RemotePath, to: RemotePath) async throws {
        try requireAbsent(to, source: from)
        try mapErrors(from) { try FileManager.default.moveItem(atPath: from.string, toPath: to.string) }
    }

    public func copy(_ from: RemotePath, to: RemotePath) async throws {
        try requireAbsent(to, source: from)
        try mapErrors(from) { try FileManager.default.copyItem(atPath: from.string, toPath: to.string) }
    }

    public func delete(_ path: RemotePath) async throws {
        try mapErrors(path) { try FileManager.default.removeItem(atPath: path.string) }
    }

    public func trash(_ path: RemotePath) async throws {
        try mapErrors(path) { try FileManager.default.trashItem(at: url(path), resultingItemURL: nil) }
    }

    // MARK: - Helpers

    private func url(_ path: RemotePath) -> URL {
        URL(fileURLWithPath: path.string)
    }

    /// Describes `path`. Without `followingGuardedLinks`, a link into a privacy-guarded
    /// folder stays `.other`, since looking at its target would make macOS ask the user.
    private func item(at path: RemotePath, followingGuardedLinks: Bool) throws -> FileItem {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: path.string)
        let type = attributes[.type] as? FileAttributeType
        let isLink = type == .typeSymbolicLink
        var kind: FileItem.Kind = switch type {
        case .typeDirectory: .directory
        case .typeRegular: .file
        default: .other
        }
        if isLink, followingGuardedLinks || !linksIntoGuardedFolder(path) {
            // Describe what the link points at, so a link to a folder opens like one.
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: path.string, isDirectory: &isDirectory) {
                kind = isDirectory.boolValue ? .directory : .file
            }
        }
        return FileItem(
            path: path,
            kind: kind,
            isSymbolicLink: isLink,
            size: kind == .directory ? nil : (attributes[.size] as? NSNumber)?.int64Value,
            modified: attributes[.modificationDate] as? Date,
            permissions: (attributes[.posixPermissions] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) },
            owner: attributes[.ownerAccountName] as? String
        )
    }

    /// Reading the link itself is fine; only its target is guarded.
    private func linksIntoGuardedFolder(_ link: RemotePath) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.string) else {
            return false
        }
        let target = destination.hasPrefix("/") ? RemotePath(destination) : (link.parent ?? .root).appending(destination)
        return privacy.isGuarded(target)
    }

    private func requireDirectory(_ path: RemotePath) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.string, isDirectory: &isDirectory) else {
            throw ProviderError.notFound(path)
        }
        guard isDirectory.boolValue else { throw ProviderError.notADirectory(path) }
    }

    private func requireFile(_ path: RemotePath) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.string, isDirectory: &isDirectory) else {
            throw ProviderError.notFound(path)
        }
        guard !isDirectory.boolValue else { throw ProviderError.isADirectory(path) }
    }

    private func requireAbsent(_ destination: RemotePath, source: RemotePath) throws {
        guard FileManager.default.fileExists(atPath: source.string) else { throw ProviderError.notFound(source) }
        guard !FileManager.default.fileExists(atPath: destination.string) else {
            throw ProviderError.alreadyExists(destination)
        }
    }

    private func mapErrors<T>(_ path: RemotePath, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw Self.translate(error, path)
        }
    }

    static func translate(_ error: any Error, _ path: RemotePath) -> any Error {
        switch error {
        case is ProviderError, is CancellationError:
            return error
        case let error as CocoaError:
            switch error.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return ProviderError.notFound(path)
            case .fileWriteFileExists: return ProviderError.alreadyExists(path)
            case .fileReadNoPermission, .fileWriteNoPermission: return ProviderError.permissionDenied(path)
            default:
                if let posix = error.underlying as? POSIXError { return translate(posix, path) }
                return ProviderError.io(error.localizedDescription)
            }
        case let error as POSIXError:
            switch error.code {
            case .ENOENT: return ProviderError.notFound(path)
            case .EEXIST: return ProviderError.alreadyExists(path)
            case .EACCES, .EPERM: return ProviderError.permissionDenied(path)
            case .ENOTDIR: return ProviderError.notADirectory(path)
            case .EISDIR: return ProviderError.isADirectory(path)
            default: return ProviderError.io(error.localizedDescription)
            }
        default:
            return ProviderError.io(error.localizedDescription)
        }
    }
}
