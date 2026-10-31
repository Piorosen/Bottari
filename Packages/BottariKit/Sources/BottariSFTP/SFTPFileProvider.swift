import BottariCore
import Citadel
import Foundation
import NIOCore
import Synchronization

/// Browses one SFTP server over a single SSH connection.
public struct SFTPFileProvider: FileProvider {
    public let displayName: String
    public let home: RemotePath
    public let endpoint: SFTPEndpoint
    /// The jump hosts the connection goes through, outermost first.
    public let jumps: [SFTPEndpoint]
    /// Whether this account may run commands. Most may; SFTP-only accounts
    /// (chroot jails, many NAS boxes) may not.
    public let canRunCommands: Bool
    let link: SFTPLink
    /// How another server can send files straight here, if it can.
    let directReach: DirectReach?

    /// Bytes asked for per read request. Servers may answer with less.
    static let chunkSize: UInt32 = 128 * 1024
    /// Requests kept in flight at once. Waiting for each answer before sending
    /// the next would make every chunk cost a full round trip to the server.
    static let readsInFlight = 8
    static let writesInFlight = 32
    /// Bytes per write request; bigger SSH packets trip swift-nio-ssh (apple/swift-nio-ssh#99).
    static let writeSliceSize = 32_000

    public var capabilities: ProviderCapabilities {
        var capabilities: ProviderCapabilities = [.rangeRead, .resumableWrite, .modificationTime, .permissions]
        if canRunCommands {
            capabilities.formUnion([.exec, .serverSideCopy, .checksum, .symbolicLinks])
        }
        return capabilities
    }
    /// The account and the jump hosts on the way: behind different jump hosts,
    /// the same `user@127.0.0.1:port` can be different machines, and treating
    /// them as one would rename files on one server instead of sending them.
    public var locationID: String {
        let target = "sftp://\(endpoint.username)@\(endpoint.hostKeyID)"
        guard !jumps.isEmpty else { return target }
        return target + " via " + jumps.map { "\($0.username)@\($0.hostKeyID)" }.joined(separator: ",")
    }

    public static func connect(
        to endpoint: SFTPEndpoint,
        credential: SFTPCredential,
        hostKeys: HostKeyTrust,
        via hops: [SSHHop] = [],
        proxyCommand: String? = nil,
        displayName: String? = nil
    ) async throws -> SFTPFileProvider {
        let reopen: @Sendable () async throws -> SFTPConnection = {
            try await SFTPConnection.open(to: endpoint, credential: credential, hostKeys: hostKeys, via: hops, proxyCommand: proxyCommand)
        }
        let connection = try await reopen()
        do {
            let home = RemotePath(try await connection.sftp.getRealPath(atPath: "."))
            return SFTPFileProvider(
                displayName: displayName ?? endpoint.host,
                home: home,
                endpoint: endpoint,
                jumps: hops.map(\.endpoint),
                canRunCommands: await probeCommands(on: connection),
                link: SFTPLink(connection, reopen: reopen),
                directReach: proxyCommand == nil ? DirectReach(endpoint: endpoint, credential: credential, hops: hops, hostKeys: hostKeys) : nil
            )
        } catch {
            await connection.close()
            throw SFTPConnectError.wrap(error)
        }
    }

    public func disconnect() async {
        await link.close()
    }

    /// The same for every copy of this provider, different for each connection.
    /// It stays the same when a dropped connection is opened again.
    public var connectionID: ObjectIdentifier { ObjectIdentifier(link) }

    public var isConnected: Bool { link.current.client.isConnected }

    /// Runs `action` whenever the SSH connection drops (or is closed). The next
    /// request opens it again; this is for whoever holds channels on it.
    public func whenDisconnected(_ action: @escaping @Sendable () -> Void) {
        link.whenDisconnected(action)
    }

    // MARK: - FileProvider

    public func list(_ path: RemotePath) async throws -> [FileItem] {
        let names: [SFTPMessage.Name]
        let sftp: SFTPClient
        do {
            (names, sftp) = try await link.retrying { connection in
                (try await connection.sftp.listDirectory(atPath: path.string), connection.sftp)
            }
        } catch {
            throw await refine(error, path, expectingDirectory: true)
        }
        let entries = names.flatMap(\.components).filter { $0.filename != "." && $0.filename != ".." }
        var items = entries.map { Self.item(path.appending($0.filename), $0.attributes, longname: $0.longname) }
        // Describe what each link points at, so a link to a folder opens like
        // one. A folder of links (/usr/lib) can hold thousands, so several
        // are asked about at once rather than one round trip after another.
        var links = items.indices.filter { items[$0].isSymbolicLink }.map { ($0, items[$0].path.string) }.makeIterator()
        let client = UncheckedSendable(sftp)
        await withTaskGroup(of: (Int, SFTPFileAttributes?).self) { group in
            func askNext() {
                guard let (index, linkPath) = links.next() else { return }
                group.addTask { (index, try? await client.value.getAttributes(at: linkPath)) }
            }
            for _ in 0..<Self.linksAskedAtOnce { askNext() }
            for await (index, target) in group {
                if let target {
                    items[index] = Self.item(items[index].path, target, longname: entries[index].longname, isSymbolicLink: true)
                }
                askNext()
            }
        }
        return items.sorted(by: FileItem.finderOrder)
    }

    static let linksAskedAtOnce = 16

    public func stat(_ path: RemotePath) async throws -> FileItem {
        do {
            return Self.item(path, try await link.retrying { try await $0.sftp.getAttributes(at: path.string) })
        } catch {
            throw Self.translate(error, path)
        }
    }

    public func read(_ path: RemotePath, range: Range<Int64>?) -> AsyncThrowingStream<Data, any Error> {
        let reader = Reader(link: link, path: path, start: range?.lowerBound ?? 0, end: range?.upperBound ?? .max)
        return AsyncThrowingStream(unfolding: {
            do {
                return try await reader.next()
            } catch {
                throw await refine(error, path, expectingDirectory: false)
            }
        })
    }

    public func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws {
        try await write(path, from: data, resumingAt: 0)
    }

    public func write(_ given: RemotePath, from data: AsyncThrowingStream<Data, any Error>, resumingAt offset: Int64) async throws {
        let sftp = try await link.live().sftp
        // Saving through a link writes the file it points to, as an editor
        // would, instead of replacing the link with a plain file.
        let path = await Self.followingLinks(given, on: sftp)
        guard let parent = path.parent else { throw ProviderError.permissionDenied(path) }
        // Upload next to the target and swap it in at the end, so a dropped
        // connection never leaves a half-written file where the original was.
        // What was written stays in the partial file so a retry can resume.
        let temp = path.partialWritePath
        let file: SFTPFile
        do {
            if offset > 0 {
                // Drop anything past the point the caller resumes from.
                try await sftp.setAttributes(at: temp.string, to: SFTPFileAttributes(size: UInt64(offset)))
            }
            file = try await sftp.openFile(filePath: temp.string, flags: offset > 0 ? [.write] : [.write, .create, .truncate])
        } catch {
            // A folder where only its files may be written (a group-writable
            // config under /etc, say) has no room for a file beside them, so
            // the file is rewritten where it is, as vi would.
            if offset == 0, case ProviderError.permissionDenied = Self.translate(error, path), (try? await sftp.getAttributes(at: path.string)) != nil {
                return try await writeInPlace(path, from: data, on: sftp)
            }
            throw Self.translate(error, path)
        }
        do {
            try await Self.write(UncheckedSendable(file), from: data, startingAt: UInt64(offset))
            try await file.close()
        } catch {
            try? await file.close()
            throw Self.translate(error, path)
        }
        do {
            try await swapIntoPlace(temp, path, backup: parent.appending(".\(path.name).bottari-old"), on: sftp)
        } catch {
            // Everything was written; what went wrong is the destination itself
            // (a folder in the way, no permission), so a resume would not help.
            try? await sftp.remove(at: temp.string)
            throw Self.translate(error, path)
        }
    }

    /// Where writing to `path` should land: the file a link there points to,
    /// or `path` itself when it is no link or does not exist yet.
    static func followingLinks(_ path: RemotePath, on sftp: SFTPClient) async -> RemotePath {
        guard (try? await sftp.getAttributes(at: path.string)) != nil,
              let real = try? await sftp.getRealPath(atPath: path.string), real.hasPrefix("/")
        else { return path }
        return RemotePath(real)
    }

    /// Truncates and rewrites the file itself. Not safe against a dropped
    /// connection, so only for when nothing can be written beside it.
    private func writeInPlace(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>, on sftp: SFTPClient) async throws {
        do {
            let file = try await sftp.openFile(filePath: path.string, flags: [.write, .truncate])
            do {
                try await Self.write(UncheckedSendable(file), from: data, startingAt: 0)
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        } catch {
            throw Self.translate(error, path)
        }
    }

    public func setModified(_ date: Date, at path: RemotePath) async throws {
        do {
            try await link.retrying {
                try await $0.sftp.setAttributes(at: path.string, to: SFTPFileAttributes(accessModificationTime: .init(accessTime: date, modificationTime: date)))
            }
        } catch {
            throw Self.translate(error, path)
        }
    }

    public func setPermissions(_ mode: UInt16, at path: RemotePath) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = UInt32(mode & 0o7777)
        do {
            try await link.retrying { try await $0.sftp.setAttributes(at: path.string, to: attributes) }
        } catch {
            throw Self.translate(error, path)
        }
    }

    // MARK: - Commands

    /// `ln -s`: Citadel has no SFTP request for links, and OpenSSH's server
    /// takes that request's two paths in the opposite order to the spec anyway.
    public func makeSymbolicLink(at path: RemotePath, to target: String) async throws {
        guard canRunCommands else { throw ProviderError.unsupported(String(localized: "심볼릭 링크")) }
        _ = try await run("ln -s -- \(Self.quote(target)) \(Self.quote(path.string))")
    }

    /// `find` on the server when it runs commands, which is far quicker than
    /// listing every folder over SFTP; the listing walk otherwise.
    public func search(_ query: String, in folder: RemotePath, limit: Int) -> AsyncThrowingStream<FileItem, any Error> {
        guard canRunCommands else { return FileSearch.walk(self, from: folder, matching: query, limit: limit) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let pattern = trimmed.contains(where: { $0 == "*" || $0 == "?" }) ? trimmed : "*\(trimmed)*"
        // Each match comes back as "d path" or "f path"; links to folders count
        // as files. find's own status follows as "end N", unless head cut it off.
        let command = "(find \(Self.quote(folder.string)) -mindepth 1 -iname \(Self.quote(pattern)) "
            + "-exec sh -c 'for p; do if [ -d \"$p\" ] && [ ! -L \"$p\" ]; then echo \"d $p\"; else echo \"f $p\"; fi; done' sh {} + "
            + "2>/dev/null; echo \"end $?\") | head -n \(limit + 1)"
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let output = (try? await run(command)) ?? "end 127"
                    var found = 0
                    var findFailed = false
                    for line in output.split(separator: "\n") {
                        if line.hasPrefix("end ") {
                            findFailed = line != "end 0"
                        } else if line.count > 2, found < limit {
                            let kind: FileItem.Kind = line.hasPrefix("d ") ? .directory : .file
                            continuation.yield(FileItem(path: RemotePath(String(line.dropFirst(2))), kind: kind))
                            found += 1
                        }
                    }
                    // A find without -iname (or none at all) finds nothing and
                    // says so; unreadable folders also fail it, but after results.
                    if findFailed, found == 0, !Task.isCancelled {
                        for try await item in FileSearch.walk(self, from: folder, matching: query, limit: limit) {
                            continuation.yield(item)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs a shell command on the server and returns what it printed.
    public func run(_ command: String) async throws -> String {
        try await Self.run(command, on: try await link.live())
    }

    /// `cp -a`, so nothing passes through the Mac.
    public func copy(_ from: RemotePath, to: RemotePath) async throws {
        guard canRunCommands else { throw ProviderError.unsupported(String(localized: "서버 내 복사")) }
        _ = try await run("cp -a -- \(Self.quote(from.string)) \(Self.quote(to.string))")
    }

    public func checksum(_ path: RemotePath) async throws -> String {
        guard canRunCommands else { throw ProviderError.unsupported(String(localized: "체크섬")) }
        // From stdin, so the name never appears in the output: GNU sha256sum
        // marks names with a backslash or newline by prefixing the hash.
        let file = Self.quote(path.string)
        let output = try await run("sha256sum < \(file) 2>/dev/null || shasum -a 256 < \(file)")
        guard let hash = output.split(whereSeparator: \.isWhitespace).first, hash.count == 64 else {
            throw ProviderError.io(String(localized: "체크섬을 읽을 수 없습니다: \(output)"))
        }
        return hash.lowercased()
    }

    /// Packs items of one folder into a .tar.gz `archive` in that folder.
    public func compress(_ items: [RemotePath], into archive: RemotePath) async throws {
        guard let folder = archive.parent else { throw ProviderError.permissionDenied(archive) }
        let names = items.map { Self.quote($0.name) }.joined(separator: " ")
        _ = try await run("cd \(Self.quote(folder.string)) && tar -czf \(Self.quote(archive.name)) -- \(names)")
    }

    /// Unpacks a tar archive (gzip, bzip2 and xz too) or a .zip into a new folder,
    /// so nothing already there gets overwritten.
    public func extract(_ archive: RemotePath, into folder: RemotePath) async throws {
        let unpack = archive.pathExtension.lowercased() == "zip"
            ? "unzip -q \(Self.quote(archive.string)) -d \(Self.quote(folder.string))"
            : "tar -xf \(Self.quote(archive.string)) -C \(Self.quote(folder.string))"
        _ = try await run("mkdir -- \(Self.quote(folder.string)) && \(unpack)")
    }

    /// Single-quotes `text` for a POSIX shell.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs `command` with /bin/sh whatever the account's login shell is
    /// (csh and fish read `2>/dev/null` and `$(…)` differently, or not at all).
    static func run(_ command: String, on connection: SFTPConnection) async throws -> String {
        var output = ByteBuffer()
        var errors = ByteBuffer()
        do {
            for try await chunk in try await connection.client.executeCommandStream("/bin/sh -c " + quote(command)) {
                switch chunk {
                case .stdout(let buffer): output.writeImmutableBuffer(buffer)
                case .stderr(let buffer): errors.writeImmutableBuffer(buffer)
                }
            }
        } catch let failed as SSHClient.CommandFailed {
            let message = String(buffer: errors).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.io(String(localized: "서버 명령 실패 (종료 코드 \(failed.exitCode))") + (message.isEmpty ? "" : ": \(message)"))
        }
        return String(buffer: output)
    }

    /// Tries `echo` once at connect. A server that refuses or ignores exec
    /// requests gets three seconds before Bottari stops waiting.
    static func probeCommands(on connection: SFTPConnection) async -> Bool {
        let outcome = FirstAnswer()
        return await withCheckedContinuation { continuation in
            outcome.wait(with: continuation)
            let probe = connection.track {
                outcome.give((try? await run("echo bottari", on: connection))?.hasPrefix("bottari") == true)
            }
            if probe == nil { outcome.give(false) }
            Task {
                try? await Task.sleep(for: .seconds(3))
                outcome.give(false)
            }
        }
    }

    public func makeDirectory(_ path: RemotePath) async throws {
        do {
            try await link.live().sftp.createDirectory(atPath: path.string)
        } catch {
            throw await refineClash(error, path)
        }
    }

    public func move(_ from: RemotePath, to: RemotePath) async throws {
        do {
            try await link.live().sftp.rename(at: from.string, to: to.string)
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
            try await link.live().sftp.remove(at: path.string)
        } catch {
            let translated = Self.translate(error, path)
            if case ProviderError.notFound = translated { throw translated }
            guard let children = try? await list(path) else { throw translated }
            for child in children {
                try await delete(child.path)
            }
            do {
                try await link.live().sftp.rmdir(at: path.string)
            } catch {
                throw Self.translate(error, path)
            }
        }
    }

    // MARK: - Pipelining

    /// Writes the stream from `start` with several requests in flight.
    static func write(_ file: UncheckedSendable<SFTPFile>, from data: AsyncThrowingStream<Data, any Error>, startingAt start: UInt64 = 0) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var offset = start
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
            // A stream read by a cancelled task (a paused or cancelled
            // transfer) just stops, as if the file had ended there.
            try Task.checkCancellation()
            try await group.waitForAll()
        }
    }

    /// Hands out a file's bytes in order as the stream's consumer asks for them,
    /// keeping a few read requests ahead. The stream calls `next()` from one task
    /// at a time, which is what makes the mutable state safe.
    private final class Reader: @unchecked Sendable {
        private let link: SFTPLink
        /// The connection the file was opened on; its handle means nothing on another.
        private var connection: SFTPConnection?
        private let path: RemotePath
        private let end: Int64
        private var file: UncheckedSendable<SFTPFile>?
        private var nextRequest: Int64
        private var ahead: [(offset: Int64, length: Int64, data: Task<ByteBuffer, any Error>)] = []
        private var finished = false

        init(link: SFTPLink, path: RemotePath, start: Int64, end: Int64) {
            self.link = link
            self.path = path
            self.nextRequest = start
            self.end = end
        }

        deinit {
            // The consumer stopped early, e.g. a cancelled transfer or a seek.
            cancelAhead()
            if let file, let connection {
                connection.track { try? await file.value.close() }
            }
        }

        func next() async throws -> Data? {
            guard !finished else { return nil }
            do {
                try Task.checkCancellation()
                let (file, connection) = try await openedFile()
                while ahead.count < SFTPFileProvider.readsInFlight, nextRequest < end {
                    let offset = nextRequest
                    let length = min(Int64(SFTPFileProvider.chunkSize), end - offset)
                    guard let read = connection.track({ try await file.value.read(from: UInt64(offset), length: UInt32(length)) }) else {
                        throw SFTPError.connectionClosed
                    }
                    nextRequest += length
                    ahead.append((offset, length, read))
                }
                guard !ahead.isEmpty else { return await finish() }
                let chunk = ahead.removeFirst()
                let first = try await chunk.data.value
                guard first.readableBytes > 0 else { return await finish() }
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
                await closeFile()
                finished = true
                throw error
            }
        }

        private func openedFile() async throws -> (UncheckedSendable<SFTPFile>, SFTPConnection) {
            if let file, let connection { return (file, connection) }
            let connection = try await link.live()
            let opened = UncheckedSendable(try await connection.sftp.openFile(filePath: path.string, flags: .read))
            file = opened
            self.connection = connection
            return (opened, connection)
        }

        private func finish() async -> Data? {
            finished = true
            await closeFile()
            return nil
        }

        private func cancelAhead() {
            for chunk in ahead {
                chunk.data.cancel()
            }
            ahead.removeAll()
        }

        /// Waits for reads already sent, then closes the handle.
        private func closeFile() async {
            for chunk in ahead {
                _ = try? await chunk.data.value
            }
            ahead.removeAll()
            guard let file else { return }
            self.file = nil
            try? await file.value.close()
        }
    }

    // MARK: - Helpers

    /// Moves `temp` onto `path`, keeping the original's permissions. If any step
    /// fails, the original is put back.
    private func swapIntoPlace(_ temp: RemotePath, _ path: RemotePath, backup: RemotePath, on sftp: SFTPClient) async throws {
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
            guard let attributes = try? await link.live().sftp.getAttributes(at: path.string) else { return translated }
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
              let siblings = try? await link.live().sftp.listDirectory(atPath: parent.string),
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
            return ProviderError.disconnected(String(localized: "서버와의 연결이 끊어졌습니다"))
        case let failure as SFTPConnectError:
            // Reconnecting failed: a network problem may pass, a refused key will not.
            switch failure {
            case .noResponse, .refused, .unknownHost, .noRoute, .unreachable, .jumpHostFailed:
                return ProviderError.disconnected(failure.localizedDescription)
            default:
                return ProviderError.io(failure.localizedDescription)
            }
        default:
            return ProviderError.io(String(describing: error))
        }
    }

    static func translate(_ code: SFTPStatusCode, message: String, _ path: RemotePath) -> ProviderError {
        switch code {
        case .noSuchFile: .notFound(path)
        case .permissionDenied: .permissionDenied(path)
        case .unsupportedOperation: .unsupported(message.isEmpty ? "SFTP" : message)
        case .noConnection, .connectionLost: .disconnected(String(localized: "서버와의 연결이 끊어졌습니다"))
        default: .io(message.isEmpty ? String(localized: "SFTP 오류: \(String(describing: code))") : message)
        }
    }
}
