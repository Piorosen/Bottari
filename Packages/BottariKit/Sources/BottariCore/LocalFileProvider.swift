import CryptoKit
import Foundation

/// The Mac's own disk. A `RemotePath` is simply the absolute file path.
public struct LocalFileProvider: FileProvider {
    public let displayName: String
    public let home: RemotePath
    public let privacy: PrivacyGuard

    static let chunkSize = 256 * 1024
    public static let locationID = "local"

    public var locationID: String { Self.locationID }

    public init(displayName: String = String(localized: "이 Mac"), home: RemotePath = RemotePath(NSHomeDirectory()), privacy: PrivacyGuard = PrivacyGuard()) {
        self.displayName = displayName
        self.home = home
        self.privacy = privacy
    }

    public var capabilities: ProviderCapabilities { [.rangeRead, .serverSideCopy, .trash, .checksum, .resumableWrite, .modificationTime, .permissions, .symbolicLinks] }

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
        let reader = Reader(start: range?.lowerBound ?? 0, end: range?.upperBound ?? .max) {
            try requireFile(path)
            return try mapErrors(path) { try FileHandle(forReadingFrom: url(path)) }
        }
        return AsyncThrowingStream(unfolding: { try reader.next() })
    }

    /// Reads one chunk each time the stream's consumer asks. The stream calls
    /// `next()` from one task at a time, which is what makes the mutable state safe.
    private final class Reader: @unchecked Sendable {
        private let open: () throws -> FileHandle
        private var handle: FileHandle?
        private var offset: Int64
        private let end: Int64

        init(start: Int64, end: Int64, open: @escaping () throws -> FileHandle) {
            self.offset = start
            self.end = end
            self.open = open
        }

        deinit {
            try? handle?.close()
        }

        func next() throws -> Data? {
            try Task.checkCancellation()
            guard offset < end else { return finish() }
            let handle = try self.handle ?? {
                let opened = try open()
                try opened.seek(toOffset: UInt64(offset))
                self.handle = opened
                return opened
            }()
            let count = Int(min(Int64(LocalFileProvider.chunkSize), end - offset))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { return finish() }
            offset += Int64(data.count)
            return data
        }

        private func finish() -> Data? {
            try? handle?.close()
            handle = nil
            offset = end
            return nil
        }
    }

    public func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws {
        try await write(path, from: data, resumingAt: 0)
    }

    public func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>, resumingAt offset: Int64) async throws {
        guard let parent = path.parent else { throw ProviderError.permissionDenied(path) }
        try requireDirectory(parent)
        let fm = FileManager.default
        // Write next to the destination and swap it in at the end, so a failed
        // transfer never leaves a half-written file where the original was.
        // What was written stays in the partial file so a retry can resume.
        let temp = path.partialWritePath
        do {
            if offset == 0 {
                try mapErrors(parent) { try Data().write(to: url(temp)) }
            }
            let handle = try FileHandle(forWritingTo: url(temp))
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seek(toOffset: UInt64(offset))
            do {
                for try await chunk in data {
                    try handle.write(contentsOf: chunk)
                }
                // A stream read by a cancelled task (a paused or cancelled
                // transfer) just stops, as if the file had ended there; what
                // arrived stays partial instead of becoming the file.
                try Task.checkCancellation()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } catch {
            throw Self.translate(error, path)
        }
        do {
            if let existing = try? fm.attributesOfItem(atPath: path.string),
               let mode = existing[.posixPermissions] {
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.string)
            }
            guard rename(temp.string, path.string) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            // Everything was written; the destination itself is the problem
            // (a folder in the way, no permission), so a resume would not help.
            try? fm.removeItem(atPath: temp.string)
            throw Self.translate(error, path)
        }
    }

    public func checksum(_ path: RemotePath) async throws -> String {
        var hash = SHA256()
        for try await chunk in read(path, range: nil) {
            hash.update(data: chunk)
        }
        try Task.checkCancellation()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func setModified(_ date: Date, at path: RemotePath) async throws {
        try mapErrors(path) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.string)
        }
    }

    public func makeDirectory(_ path: RemotePath) async throws {
        try mapErrors(path) {
            try FileManager.default.createDirectory(atPath: path.string, withIntermediateDirectories: false)
        }
    }

    /// Leaves out folders macOS guards with a privacy prompt, unless the search
    /// starts inside one: finding a file should not make macOS stop and ask.
    public func search(_ query: String, in folder: RemotePath, limit: Int) -> AsyncThrowingStream<FileItem, any Error> {
        let privacy = privacy
        let insideGuarded = privacy.isGuarded(folder)
        return FileSearch.walk(self, from: folder, matching: query, limit: limit) { child in
            insideGuarded || !privacy.isGuardedFolder(child.path)
        }
    }

    public func setPermissions(_ mode: UInt16, at path: RemotePath) async throws {
        try mapErrors(path) {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path.string)
        }
    }

    public func makeSymbolicLink(at path: RemotePath, to target: String) async throws {
        try mapErrors(path) {
            try FileManager.default.createSymbolicLink(atPath: path.string, withDestinationPath: target)
        }
    }

    public func move(_ from: RemotePath, to: RemotePath) async throws {
        try requireAbsent(to, source: from)
        if isRespelling(from, as: to) {
            // Only the spelling changes; rename(2) does that in place.
            guard rename(from.string, to.string) == 0 else { throw ProviderError.io(String(cString: strerror(errno))) }
            return
        }
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
        var attributes = try fm.attributesOfItem(atPath: path.string)
        let type = attributes[.type] as? FileAttributeType
        let isLink = type == .typeSymbolicLink
        var kind: FileItem.Kind = switch type {
        case .typeDirectory: .directory
        case .typeRegular: .file
        default: .other
        }
        if isLink, followingGuardedLinks || !linksIntoGuardedFolder(path) {
            // Describe what the link points at, so a link to a folder opens like
            // one and a linked video reports the video's size, not the link's.
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: path.string, isDirectory: &isDirectory) {
                kind = isDirectory.boolValue ? .directory : .file
                if let target = try? fm.attributesOfItem(atPath: (path.string as NSString).resolvingSymlinksInPath) {
                    attributes[.size] = target[.size]
                    attributes[.modificationDate] = target[.modificationDate]
                }
            }
        }
        return FileItem(
            path: path,
            kind: kind,
            isSymbolicLink: isLink,
            size: kind == .directory ? nil : (attributes[.size] as? NSNumber)?.int64Value,
            modified: attributes[.modificationDate] as? Date,
            permissions: (attributes[.posixPermissions] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) },
            owner: attributes[.ownerAccountName] as? String,
            cloud: kind == .file && isInICloud(path) ? cloudState(path) : nil
        )
    }

    private func isInICloud(_ path: RemotePath) -> Bool {
        path.string.contains("/Library/Mobile Documents/")
    }

    private func cloudState(_ path: RemotePath) -> FileItem.CloudState? {
        let values = try? url(path).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey])
        guard values?.isUbiquitousItem == true else { return nil }
        if values?.ubiquitousItemIsDownloading == true { return .downloading }
        return values?.ubiquitousItemDownloadingStatus == .current ? .downloaded : .inCloud
    }

    /// Asks iCloud to bring the file down.
    public func downloadFromICloud(_ path: RemotePath) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url(path))
    }

    /// Frees the space a downloaded iCloud file takes; it stays in iCloud.
    public func removeLocalCopy(_ path: RemotePath) throws {
        try FileManager.default.evictUbiquitousItem(at: url(path))
    }

    public static var iCloudDrive: RemotePath? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: path) ? RemotePath(path) : nil
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

    /// Fails if something is at `destination`, unless that is `source` itself
    /// under another spelling (a.txt → A.txt on a disk that ignores case).
    private func requireAbsent(_ destination: RemotePath, source: RemotePath) throws {
        guard FileManager.default.fileExists(atPath: source.string) else { throw ProviderError.notFound(source) }
        guard !FileManager.default.fileExists(atPath: destination.string) || isRespelling(source, as: destination) else {
            throw ProviderError.alreadyExists(destination)
        }
    }

    /// The same item in the same folder under a name that differs only in
    /// case or Unicode form; not merely another hard link to the same file.
    private func isRespelling(_ a: RemotePath, as b: RemotePath) -> Bool {
        guard a.parent == b.parent, a.name != b.name, NameMatching.ignoringCaseAndNormalization.key(a.name) == NameMatching.ignoringCaseAndNormalization.key(b.name) else { return false }
        var first = Darwin.stat(), second = Darwin.stat()
        guard lstat(a.string, &first) == 0, lstat(b.string, &second) == 0 else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// Whether two paths (or the folders they would go in) are on one volume,
    /// where a copy can be a clone and a move a rename.
    public static func areOnSameVolume(_ a: RemotePath, _ b: RemotePath) -> Bool {
        func volume(_ path: RemotePath) -> (any NSCopying & NSSecureCoding & NSObjectProtocol)? {
            var probe = path
            while !FileManager.default.fileExists(atPath: probe.string), let parent = probe.parent { probe = parent }
            return try? URL(fileURLWithPath: probe.string).resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        }
        guard let first = volume(a), let second = volume(b) else { return true }
        return first.isEqual(second)
    }

    /// APFS and HFS+ always treat the two ways of typing "é" or "한" as one
    /// name, and ignore case unless the volume was made case-sensitive.
    public func nameMatching(in folder: RemotePath) -> NameMatching {
        // The folder may not exist yet; its nearest existing ancestor is on the same volume.
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.string), let parent = probe.parent { probe = parent }
        let values = try? url(probe).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames == true ? .ignoringNormalization : .ignoringCaseAndNormalization
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
