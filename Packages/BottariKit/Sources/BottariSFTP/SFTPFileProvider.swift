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

    public var capabilities: ProviderCapabilities { [.rangeRead] }

    private var sftp: SFTPClient { connection.sftp }

    public static func connect(
        to endpoint: SFTPEndpoint,
        credential: SFTPCredential,
        hostKeys: HostKeyTrust,
        displayName: String? = nil
    ) async throws -> SFTPFileProvider {
        let connection = try await SFTPConnection.open(to: endpoint, credential: credential, hostKeys: hostKeys)
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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let file = try await sftp.openFile(filePath: path.string, flags: .read)
                    do {
                        var offset = range?.lowerBound ?? 0
                        let end = range?.upperBound ?? .max
                        while offset < end {
                            try Task.checkCancellation()
                            let length = UInt32(min(Int64(Self.chunkSize), end - offset))
                            let buffer = try await file.read(from: UInt64(offset), length: length)
                            guard buffer.readableBytes > 0 else { break }
                            continuation.yield(Data(buffer.readableBytesView))
                            offset += Int64(buffer.readableBytes)
                        }
                        try? await file.close()
                    } catch {
                        try? await file.close()
                        throw error
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: await refine(error, path, expectingDirectory: false))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws {
        guard let parent = path.parent else { throw ProviderError.permissionDenied(path) }
        // Upload next to the target and swap it in at the end, so a dropped
        // connection never leaves a half-written file where the original was.
        let temp = parent.appending(".\(path.name).bottari-part")
        do {
            let file = try await sftp.openFile(filePath: temp.string, flags: [.write, .create, .truncate])
            do {
                var offset: UInt64 = 0
                for try await chunk in data {
                    try await file.write(ByteBuffer(bytes: chunk), at: offset)
                    offset += UInt64(chunk.count)
                }
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
