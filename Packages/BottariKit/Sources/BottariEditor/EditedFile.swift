import BottariCore
import Foundation
import Observation

/// A text file open for editing, from the Mac or a server: the version it was
/// opened or last saved as, and saving over it.
@MainActor
@Observable
public final class EditedFile {
    public enum OpenError: Error {
        case tooLarge(Int64)
        case notText
    }

    /// The server's copy changed while it was being edited.
    public struct Conflict: Sendable {
        public let theirs: String
        public let modified: Date?
        /// Both edits combined, when they touched different lines.
        public let merged: String?
    }

    public enum SaveResult {
        case saved
        /// The server's copy changed since it was opened or last saved; nothing was written.
        case conflict(Conflict)
        /// The text has characters the file's encoding cannot hold; nothing was written.
        case unencodable
        /// The check after writing failed, and the previous version was put
        /// back unless `restoreError` says why not.
        case checkFailed(any Error, restoreError: (any Error)?)
    }

    public let provider: any FileProvider
    public let item: FileItem
    public private(set) var format = TextFormat()
    /// When the server's copy was last changed, as of opening or the last save.
    public private(set) var remoteModified: Date?
    private var remoteSize: Int64?
    /// The text as last opened or saved: the base for merging and for undoing a failed check.
    private var savedText = ""
    private var savedData = Data()

    public init(provider: any FileProvider, item: FileItem) {
        self.provider = provider
        self.item = item
    }

    /// Reads the file and returns its text, refusing files over `sizeLimit` bytes.
    public func open(sizeLimit: Int64) async throws -> String {
        let current = try await provider.stat(item.path)
        if let size = current.size, size > sizeLimit { throw OpenError.tooLarge(size) }
        let data = try await provider.readData(item.path)
        guard let (text, format) = TextCodec.decode(data) else { throw OpenError.notText }
        savedText = text
        savedData = data
        self.format = format
        remoteModified = current.modified
        remoteSize = current.size
        return text
    }

    /// Uploads `text`, unless the server's copy changed since it was opened.
    /// Saving over `conflict` writes over the server's copy it found without
    /// checking again. `check` runs after writing; when it throws, the
    /// previous version is put back.
    public func save(_ text: String, over conflict: Conflict? = nil, check: (@Sendable () async throws -> Void)?) async throws -> SaveResult {
        guard let data = TextCodec.encode(text, as: format) else { return .unencodable }
        if conflict == nil {
            let current = try await provider.stat(item.path)
            if current.modified != remoteModified || current.size != remoteSize {
                let theirs = TextCodec.decode(try await provider.readData(item.path))?.text ?? ""
                let merged: String? = switch ThreeWayMerge.merge(base: savedText, mine: text, theirs: theirs) {
                case .merged(let text): text
                case .conflict: nil
                }
                return .conflict(Conflict(theirs: theirs, modified: current.modified, merged: merged))
            }
        }
        let previous = savedData
        try await provider.write(item.path, data: data)
        if let check {
            do {
                try await check()
            } catch {
                var restoreError: (any Error)?
                do {
                    try await provider.write(item.path, data: previous)
                } catch let failure {
                    restoreError = failure
                }
                await refreshRemoteState()
                return .checkFailed(error, restoreError: restoreError)
            }
        }
        savedText = text
        savedData = data
        await refreshRemoteState()
        return .saved
    }

    /// The server's copy from `conflict`, written into `folder` and named
    /// after the file and the time.
    public func keepCopy(of conflict: Conflict, in folder: URL) -> URL? {
        let stamp = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let url = folder.appending(path: "\(stamp) \(item.name)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(conflict.theirs.utf8).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func refreshRemoteState() async {
        if let current = try? await provider.stat(item.path) {
            remoteModified = current.modified
            remoteSize = current.size
        }
    }
}
