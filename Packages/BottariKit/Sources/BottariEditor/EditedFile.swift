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
        /// The server's text, or nil when its bytes are no longer text.
        public let theirs: String?
        public let modified: Date?
        /// Both edits combined, when they touched different lines.
        public let merged: String?
        /// The server's bytes as found.
        let server: Data

        init(base: String, mine: String, server: Data, modified: Date?) {
            self.server = server
            self.modified = modified
            theirs = TextCodec.decode(server)?.text
            merged = theirs.flatMap { theirs in
                switch ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) {
                case .merged(let text): text
                case .conflict: nil
                }
            }
        }
    }

    public enum SaveResult {
        case saved
        /// The server's copy changed since it was opened or last saved; nothing was written.
        case conflict(Conflict)
        /// The text has characters the file's encoding cannot hold; nothing was written.
        case unencodable
        /// The check after writing failed, and the version written over was
        /// put back unless `restoreError` says why not.
        case checkFailed(any Error, restoreError: (any Error)?)
    }

    public let provider: any FileProvider
    public let item: FileItem
    public private(set) var format = TextFormat()
    /// When the server's copy was last changed, as of opening or the last save.
    public private(set) var remoteModified: Date?
    private var remoteSize: Int64?
    /// The server's copy as last opened, saved or put back: the base for
    /// merging, and what a failed check puts back.
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
    /// version written over is put back.
    public func save(_ text: String, over conflict: Conflict? = nil, check: (@Sendable () async throws -> Void)?) async throws -> SaveResult {
        guard let data = TextCodec.encode(text, as: format) else { return .unencodable }
        if conflict == nil {
            let current = try await provider.stat(item.path)
            if current.modified != remoteModified || current.size != remoteSize {
                let server = try await provider.readData(item.path)
                return .conflict(Conflict(base: savedText, mine: text, server: server, modified: current.modified))
            }
        }
        let replaced = conflict.map { (text: $0.theirs ?? savedText, data: $0.server) } ?? (text: savedText, data: savedData)
        try await provider.write(item.path, data: data)
        if let check {
            do {
                try await check()
            } catch {
                var restoreError: (any Error)?
                do {
                    try await provider.write(item.path, data: replaced.data)
                    (savedText, savedData) = replaced
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
            try conflict.server.write(to: url)
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
