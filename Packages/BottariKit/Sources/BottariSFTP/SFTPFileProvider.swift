import BottariCore
import Citadel
import Foundation
import NIOCore

/// Browses one SFTP server over a single SSH connection.
public struct SFTPFileProvider: FileProvider {
    public let displayName: String
    public let home: RemotePath
    public let endpoint: SFTPEndpoint
    let connection: SFTPConnection

    /// Bytes asked for per read request. Servers may answer with less.
    static let chunkSize: UInt32 = 128 * 1024
    /// Requests kept in flight at once. Waiting for each answer before sending
    /// the next would make every chunk cost a full round trip to the server.
    static let readsInFlight = 8
    static let writesInFlight = 32
    /// Bytes per write request; bigger SSH packets trip swift-nio-ssh (apple/swift-nio-ssh#99).
    static let writeSliceSize = 32_000

    public var capabilities: ProviderCapabilities { [.rangeRead] }
    public var locationID: String { "sftp://\(endpoint.username)@\(endpoint.hostKeyID)" }

    private var sftp: SFTPClient { connection.sftp }

    public static func connect(
        to endpoint: SFTPEndpoint,
        credential: SFTPCredential,
        hostKeys: HostKeyTrust,
        via hops: [SSHHop] = [],
        displayName: String? = nil
    ) async throws -> SFTPFileProvider {
        let connection = try await SFTPConnection.open(to: endpoint, credential: credential, hostKeys: hostKeys, via: hops)
        do {
            let home = RemotePath(try await connection.sftp.getRealPath(atPath: "."))
            return SFTPFileProvider(
                displayName: displayName ?? endpoint.host,
                home: home,
                endpoint: endpoint,
                connection: connection
            )
        } catch {
            await connection.close()
            throw SFTPConnectError.wrap(error)
        }
    }

    public func disconnect() async {
        await connection.close()
    }

    // MARK: - FileProvider

    public func list(_ path: RemotePath) async throws -> [FileItem] {
        let names: [SFTPMessage.Name]
        do {
            names = try await sftp.listDirectory(atPath: path.string)
        } catch {
            throw await refine(error, path, expectingDirectory: true)
        }
        var items: [FileItem] = []
        for entry in names.flatMap(\.components) where entry.filename != "." && entry.filename != ".." {
            let itemPath = path.appending(entry.filename)
            var item = Self.item(itemPath, entry.attributes, longname: entry.longname)
            if item.isSymbolicLink, let target = try? await sftp.getAttributes(at: itemPath.string) {
                // Describe what the link points at, so a link to a folder opens like one.
                item = Self.item(itemPath, target, longname: entry.longname, isSymbolicLink: true)
            }
            items.append(item)
        }
        return items.sorted(by: FileItem.finderOrder)
    }

    public func stat(_ path: RemotePath) async throws -> FileItem {
        do {
            return Self.item(path, try await sftp.getAttributes(at: path.string))
        } catch {
            throw Self.translate(error, path)
        }
    }

    public func read(_ path: RemotePath, range: Range<Int64>?) -> AsyncThrowingStream<Data, any Error> {
        let reader = Reader(sftp: sftp, path: path, start: range?.lowerBound ?? 0, end: range?.upperBound ?? .max)
        return AsyncThrowingStream(unfolding: {
            do {
                return try await reader.next()
            } catch {
                throw await refine(error, path, expectingDirectory: false)
            }
        })
    }

    public func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws {
        guard let parent = path.parent else { throw ProviderError.permissionDenied(path) }
        // Upload next to the target and swap it in at the end, so a dropped
        // connection never leaves a half-written file where the original was.
        let temp = parent.appending(".\(path.name).bottari-part")
        do {
            let file = try await sftp.openFile(filePath: temp.string, flags: [.write, .create, .truncate])
            do {
                try await Self.write(UncheckedSendable(file), from: data)
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
            try await swapIntoPlace(temp, path, backup: parent.appending(".\(path.name).bottari-old"))
        } catch {
            try? await sftp.remove(at: temp.string)
            throw Self.translate(error, path)
        }
    }

    public func makeDirectory(_ path: RemotePath) async throws {
        do {
            try await sftp.createDirectory(atPath: path.string)
        } catch {
            throw await refineClash(error, path)
        }
    }

    public func move(_ from: RemotePath, to: RemotePath) async throws {
        do {
            try await sftp.rename(at: from.string, to: to.string)
        } catch {
            if case ProviderError.notFound = Self.translate(error, from) {
                throw ProviderError.notFound(from)
            }
            throw await refineClash(error, to)
        }
    }

    public func delete(_ path: RemotePath) async throws {
        do {
            // Unlink first: this also removes symlinks without following them.
            try await sftp.remove(at: path.string)
        } catch {
            let translated = Self.translate(error, path)
            if case ProviderError.notFound = translated { throw translated }
            guard let children = try? await list(path) else { throw translated }
            for child in children {
                try await delete(child.path)
            }
            do {
                try await sftp.rmdir(at: path.string)
            } catch {
                throw Self.translate(error, path)
            }
        }
    }

    // MARK: - Pipelining

    /// Writes the stream from offset 0 with several requests in flight.
    static func write(_ file: UncheckedSendable<SFTPFile>, from data: AsyncThrowingStream<Data, any Error>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var offset: UInt64 = 0
            var inFlight = 0
            for try await chunk in data {
                var rest = ByteBuffer(bytes: chunk)
                while rest.readableBytes > 0, let slice = rest.readSlice(length: min(writeSliceSize, rest.readableBytes)) {
                    if inFlight == writesInFlight {
                        try await group.next()
                        inFlight -= 1
                    }
                    let at = offset
                    group.addTask { try await file.value.write(slice, at: at) }
                    inFlight += 1
                    offset += UInt64(slice.readableBytes)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Hands out a file's bytes in order as the stream's consumer asks for them,
    /// keeping a few read requests ahead. The stream calls `next()` from one task
    /// at a time, which is what makes the mutable state safe.
    private final class Reader: @unchecked Sendable {
        private let sftp: SFTPClient
        private let path: RemotePath
        private let end: Int64
        private var file: UncheckedSendable<SFTPFile>?
        private var nextRequest: Int64
        private var ahead: [(offset: Int64, length: Int64, data: Task<ByteBuffer, any Error>)] = []
        private var finished = false

        init(sftp: SFTPClient, path: RemotePath, start: Int64, end: Int64) {
            self.sftp = sftp
            self.path = path
            self.nextRequest = start
            self.end = end
        }

        deinit {
            // The consumer stopped early, e.g. a cancelled transfer.
            close()
        }

        func next() async throws -> Data? {
            guard !finished else { return nil }
            do {
                try Task.checkCancellation()
                let file = try await openedFile()
                while ahead.count < SFTPFileProvider.readsInFlight, nextRequest < end {
                    let offset = nextRequest
                    let length = min(Int64(SFTPFileProvider.chunkSize), end - offset)
                    nextRequest += length
                    ahead.append((offset, length, Task { try await file.value.read(from: UInt64(offset), length: UInt32(length)) }))
                }
                guard !ahead.isEmpty else { return finish() }
                let chunk = ahead.removeFirst()
                let first = try await chunk.data.value
                guard first.readableBytes > 0 else { return finish() }
                var data = Data(first.readableBytesView)
                // Servers may answer with less than asked, e.g. at the end of the
                // file. Fill the rest of this chunk before moving on.
                let chunkEnd = chunk.offset + chunk.length
                while chunk.offset + Int64(data.count) < chunkEnd {
                    let filled = chunk.offset + Int64(data.count)
                    let more = try await file.value.read(from: UInt64(filled), length: UInt32(chunkEnd - filled))
                    guard more.readableBytes > 0 else {
                        // The file ended inside this chunk; nothing after it can follow.
                        cancelAhead()
                        nextRequest = end
                        break
                    }
                    data.append(contentsOf: more.readableBytesView)
                }
                return data
            } catch {
                close()
                finished = true
                throw error
            }
        }

        private func openedFile() async throws -> UncheckedSendable<SFTPFile> {
            if let file { return file }
            let opened = UncheckedSendable(try await sftp.openFile(filePath: path.string, flags: .read))
            file = opened
            return opened
        }

        private func finish() -> Data? {
            finished = true
            close()
            return nil
        }

        private func cancelAhead() {
            for chunk in ahead {
                chunk.data.cancel()
            }
            ahead.removeAll()
        }

        private func close() {
            cancelAhead()
            guard let file else { return }
            self.file = nil
            Task { try? await file.value.close() }
        }
    }

    // MARK: - Helpers

    /// Moves `temp` onto `path`, keeping the original's permissions. If any step
    /// fails, the original is put back.
    private func swapIntoPlace(_ temp: RemotePath, _ path: RemotePath, backup: RemotePath) async throws {
        try? await sftp.remove(at: backup.string)
        var hadOriginal = true
        do {
            try await sftp.rename(at: path.string, to: backup.string)
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            hadOriginal = false
        }
        if hadOriginal, let mode = try? await sftp.getAttributes(at: backup.string).permissions {
            if mode & 0o170000 == 0o040000 {
                try? await sftp.rename(at: backup.string, to: path.string)
                throw ProviderError.isADirectory(path)
            }
            var attributes = SFTPFileAttributes()
            attributes.permissions = mode & 0o7777
            try? await sftp.setAttributes(at: temp.string, to: attributes)
        }
        do {
            try await sftp.rename(at: temp.string, to: path.string)
        } catch {
            if hadOriginal {
                try? await sftp.rename(at: backup.string, to: path.string)
            }
            throw error
        }
        if hadOriginal {
            try? await sftp.remove(at: backup.string)
        }
    }

    /// OpenSSH answers "not a directory" with "no such file", and reading a
    /// directory with a generic failure. Look closer before reporting either.
    private func refine(_ error: any Error, _ path: RemotePath, expectingDirectory: Bool) async -> any Error {
        let translated = Self.translate(error, path)
        switch translated {
        case ProviderError.notFound, ProviderError.io:
            guard let attributes = try? await sftp.getAttributes(at: path.string) else { return translated }
            let isDirectory = attributes.permissions.map { $0 & 0o170000 == 0o040000 } ?? false
            if expectingDirectory, !isDirectory { return ProviderError.notADirectory(path) }
            if !expectingDirectory, isDirectory { return ProviderError.isADirectory(path) }
            return translated
        default:
            return translated
        }
    }

    /// SFTP v3 reports a name clash as a generic failure; check the parent listing to say so.
    private func refineClash(_ error: any Error, _ path: RemotePath) async -> any Error {
        let translated = Self.translate(error, path)
        guard case ProviderError.io = translated,
              let parent = path.parent,
              let siblings = try? await sftp.listDirectory(atPath: parent.string),
              siblings.flatMap(\.components).contains(where: { $0.filename == path.name })
        else { return translated }
        return ProviderError.alreadyExists(path)
    }

    static func item(
        _ path: RemotePath,
        _ attributes: SFTPFileAttributes,
        longname: String = "",
        isSymbolicLink: Bool? = nil
    ) -> FileItem {
        let mode = attributes.permissions
        let type = mode.map { $0 & 0o170000 }
        let kind: FileItem.Kind = switch type {
        case 0o040000: .directory
        case 0o100000: .file
        default: .other
        }
        return FileItem(
            path: path,
            kind: kind,
            isSymbolicLink: isSymbolicLink ?? (type == 0o120000),
            size: kind == .directory ? nil : attributes.size.map { Int64(clamping: $0) },
            modified: attributes.accessModificationTime?.modificationTime,
            permissions: mode.map { UInt16(truncatingIfNeeded: $0 & 0o7777) },
            owner: owner(fromLongname: longname)
        )
    }

    /// The owner column of an `ls -l` style line, which SFTP v3 servers send with each entry.
    static func owner(fromLongname longname: String) -> String? {
        let fields = longname.split(whereSeparator: \.isWhitespace)
        return fields.count >= 4 ? String(fields[2]) : nil
    }

    static func translate(_ error: any Error, _ path: RemotePath) -> any Error {
        switch error {
        case is ProviderError, is CancellationError:
            return error
        case let status as SFTPMessage.Status:
            return translate(status.errorCode, message: status.message, path)
        case SFTPError.errorStatus(let status):
            return translate(status.errorCode, message: status.message, path)
        case SFTPError.connectionClosed:
            return ProviderError.io("서버와 연결이 끊겼어요")
        default:
            return ProviderError.io(String(describing: error))
        }
    }

    static func translate(_ code: SFTPStatusCode, message: String, _ path: RemotePath) -> ProviderError {
        switch code {
        case .noSuchFile: .notFound(path)
        case .permissionDenied: .permissionDenied(path)
        case .unsupportedOperation: .unsupported(message.isEmpty ? "SFTP" : message)
        case .noConnection, .connectionLost: .io("서버와 연결이 끊겼어요")
        default: .io(message.isEmpty ? "SFTP 오류: \(code)" : message)
        }
    }
}
