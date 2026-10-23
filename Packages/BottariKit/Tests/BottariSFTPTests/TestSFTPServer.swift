import BottariCore
import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
@testable import BottariSFTP

/// An SSH server running inside the test process. Its SFTP subsystem serves a
/// fresh temporary directory as `/`, so tests need no container or real host.
///
/// Citadel's server never answers a failed stat, open or opendir (the client
/// would wait forever), so tests only hit missing paths through operations that
/// reply with a status code: remove, mkdir, rmdir and rename.
final class TestSFTPServer {
    static let username = "tester"
    static let password = "secret"

    let root: URL
    let port: Int
    let clientKey: Curve25519.Signing.PrivateKey
    private let server: SSHServer

    var endpoint: SFTPEndpoint {
        SFTPEndpoint(host: "127.0.0.1", port: port, username: Self.username)
    }

    private init(root: URL, port: Int, clientKey: Curve25519.Signing.PrivateKey, server: SSHServer) {
        self.root = root
        self.port = port
        self.clientKey = clientKey
        self.server = server
    }

    /// With `forwarding`, the server also opens direct-tcpip channels, so it can act as a jump host.
    /// With `commands`, it runs exec requests (see `ShellExecDelegate`) and offers
    /// an interactive "shell" that answers each line in capitals.
    static func start(port fixedPort: Int? = nil, forwarding: Bool = false, commands: Bool = false) async throws -> TestSFTPServer {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BottariSFTP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clientKey = Curve25519.Signing.PrivateKey()
        let auth = TestAuthentication(
            username: username,
            password: password,
            publicKey: NIOSSHPrivateKey(ed25519Key: clientKey).publicKey
        )
        var lastError: (any Error)?
        for _ in 0..<5 {
            let port = fixedPort ?? Int.random(in: 30000..<60000)
            do {
                let server = try await SSHServer.host(
                    host: "127.0.0.1",
                    port: port,
                    hostKeys: [NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())],
                    authenticationDelegate: auth
                )
                server.enableSFTP(withDelegate: LocalDirectorySFTPDelegate(root: root))
                if forwarding {
                    server.enableDirectTCPIP(withDelegate: ForwardingDelegate())
                }
                if commands {
                    server.enableExec(withDelegate: ShellExecDelegate(root: root))
                    server.enableShell(withDelegate: ShoutingShell())
                }
                return TestSFTPServer(root: root, port: port, clientKey: clientKey, server: server)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CancellationError()
    }

    func stop() async {
        try? await server.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// The on-disk location of a server path, for arranging and checking fixtures.
    func url(_ path: RemotePath) -> URL {
        LocalDirectorySFTPDelegate(root: root).url(path.string)
    }

    func makeFile(_ path: RemotePath, _ contents: String, mode: Int = 0o644) throws {
        try Data(contents.utf8).write(to: url(path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url(path).path)
    }

    func makeDirectory(_ path: RemotePath) throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    func contents(_ path: RemotePath) throws -> String {
        String(decoding: try Data(contentsOf: url(path)), as: UTF8.self)
    }

    func names(in path: RemotePath) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url(path).path).sorted()
    }
}

/// Opens a TCP connection for each direct-tcpip request and copies bytes both
/// ways, like `sshd` does for ProxyJump. Citadel has already put a codec on the
/// SSH channel, so both sides speak plain ByteBuffers. (Citadel's own forwarding
/// delegate wires its handlers on the outbound side, so bytes never reach the target.)
private struct ForwardingDelegate: DirectTCPIPDelegate {
    func initializeDirectTCPIPChannel(_ channel: Channel, request: SSHChannelType.DirectTCPIP, context: SSHContext) -> EventLoopFuture<Void> {
        ClientBootstrap(group: channel.eventLoop)
            .connect(host: request.targetHost, port: request.targetPort)
            .flatMap { remote in
                do {
                    try channel.pipeline.syncOperations.addHandler(SSHToRemote(remote: remote))
                    try remote.pipeline.syncOperations.addHandler(RemoteToSSH(ssh: channel))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    remote.close(promise: nil)
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
    }
}

private final class SSHToRemote: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let remote: Channel

    init(remote: Channel) {
        self.remote = remote
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        remote.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        remote.close(promise: nil)
    }
}

private final class RemoteToSSH: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let ssh: Channel

    init(ssh: Channel) {
        self.ssh = ssh
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        ssh.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        ssh.close(promise: nil)
    }
}

private struct TestAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let username: String
    let password: String
    let publicKey: NIOSSHPublicKey

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.password, .publicKey] }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == username else {
            responsePromise.succeed(.failure)
            return
        }
        switch request.request {
        case .password(let attempt):
            responsePromise.succeed(attempt.password == password ? .success : .failure)
        case .publicKey(let attempt):
            responsePromise.succeed(attempt.publicKey == publicKey ? .success : .failure)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

/// Serves `root` as the SFTP file system, answering like OpenSSH's sftp-server
/// where it matters: generic failure on name clashes, lstat for listings.
private struct LocalDirectorySFTPDelegate: SFTPDelegate {
    let root: URL

    func url(_ path: String) -> URL {
        let relative = RemotePath(path).components.joined(separator: "/")
        return relative.isEmpty ? root : root.appendingPathComponent(relative)
    }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    static func attributes(of url: URL, followingLinks: Bool) throws -> SFTPFileAttributes {
        var info = try FileManager.default.attributesOfItem(atPath: url.path)
        if followingLinks, info[.type] as? FileAttributeType == .typeSymbolicLink {
            info = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        }
        let typeBits: UInt32 = switch info[.type] as? FileAttributeType {
        case .typeDirectory?: 0o040000
        case .typeSymbolicLink?: 0o120000
        default: 0o100000
        }
        let modified = info[.modificationDate] as? Date ?? Date()
        var attributes = SFTPFileAttributes(
            size: (info[.size] as? NSNumber)?.uint64Value,
            accessModificationTime: .init(accessTime: modified, modificationTime: modified)
        )
        attributes.permissions = typeBits | ((info[.posixPermissions] as? NSNumber)?.uint32Value ?? 0)
        return attributes
    }

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        try Self.attributes(of: url(path), followingLinks: true)
    }

    func openFile(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        flags: SFTPOpenFileFlags,
        context: SSHContext
    ) async throws -> SFTPFileHandle {
        let url = url(filePath)
        if flags.contains(.create), !exists(url) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = flags.contains(.write) ? try FileHandle(forUpdating: url) : try FileHandle(forReadingFrom: url)
        if flags.contains(.truncate) {
            try handle.truncate(atOffset: 0)
        }
        return LocalFile(handle: handle, url: url)
    }

    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        let url = url(filePath)
        guard exists(url) else { return .noSuchFile }
        guard !isDirectory(url) else { return .failure }
        try FileManager.default.removeItem(at: url)
        return .ok
    }

    func createDirectory(_ filePath: String, withAttributes: SFTPFileAttributes, context: SSHContext) async throws -> SFTPStatusCode {
        let url = url(filePath)
        guard !exists(url) else { return .failure }
        guard isDirectory(url.deletingLastPathComponent()) else { return .noSuchFile }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return .ok
    }

    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        let url = url(filePath)
        guard exists(url) else { return .noSuchFile }
        guard isDirectory(url), try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else { return .failure }
        try FileManager.default.removeItem(at: url)
        return .ok
    }

    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        [SFTPPathComponent(filename: RemotePath(canonicalUrl).string, longname: "", attributes: .none)]
    }

    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        let url = url(path)
        let here = try Self.attributes(of: url, followingLinks: true)
        var entries = [
            SFTPPathComponent(filename: ".", longname: "", attributes: here),
            SFTPPathComponent(filename: "..", longname: "", attributes: here),
        ]
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
            let attributes = try Self.attributes(of: url.appendingPathComponent(name), followingLinks: false)
            let longname = "-rw-r--r--    1 \(TestSFTPServer.username)   staff   \(attributes.size ?? 0) Oct 23 14:00 \(name)"
            entries.append(SFTPPathComponent(filename: name, longname: longname, attributes: attributes))
        }
        // Answer in several READDIR replies, as real servers do for bigger folders.
        let replies = stride(from: 0, to: entries.count, by: 3).map {
            SFTPFileListing(path: Array(entries[$0..<min($0 + 3, entries.count)]))
        }
        return DirectoryListing(replies: replies)
    }

    func setFileAttributes(to attributes: SFTPFileAttributes, atPath path: String, context: SSHContext) async throws -> SFTPStatusCode {
        if let permissions = attributes.permissions {
            try FileManager.default.setAttributes([.posixPermissions: Int(permissions & 0o7777)], ofItemAtPath: url(path).path)
        }
        if let times = attributes.accessModificationTime {
            try FileManager.default.setAttributes([.modificationDate: times.modificationTime], ofItemAtPath: url(path).path)
        }
        if let size = attributes.size {
            let handle = try FileHandle(forWritingTo: url(path))
            try handle.truncate(atOffset: size)
            try handle.close()
        }
        return .ok
    }

    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode {
        try FileManager.default.createSymbolicLink(atPath: url(linkPath).path, withDestinationPath: url(targetPath).path)
        return .ok
    }

    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url(path).path)
        return [SFTPPathComponent(filename: destination, longname: "", attributes: .none)]
    }

    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode {
        let source = url(oldPath), destination = url(newPath)
        guard exists(source) else { return .noSuchFile }
        guard !exists(destination) else { return .failure }
        try FileManager.default.moveItem(at: source, to: destination)
        return .ok
    }
}

private struct DirectoryListing: SFTPDirectoryHandle {
    let replies: [SFTPFileListing]

    func listFiles(context: SSHContext) async throws -> [SFTPFileListing] {
        replies
    }
}

private final class LocalFile: SFTPFileHandle {
    let handle: FileHandle
    let url: URL

    init(handle: FileHandle, url: URL) {
        self.handle = handle
        self.url = url
    }

    func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(min(length, 1 << 20))) ?? Data()
        return ByteBuffer(bytes: data)
    }

    func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(data.readableBytesView))
        return .ok
    }

    func close() async throws -> SFTPStatusCode {
        try handle.close()
        return .ok
    }

    func readFileAttributes() async throws -> SFTPFileAttributes {
        try LocalDirectorySFTPDelegate.attributes(of: url, followingLinks: true)
    }

    func setFileAttributes(to attributes: SFTPFileAttributes) async throws {}
}

/// Runs exec requests with /bin/sh as if the test root were the server's `/`.
/// Bottari single-quotes every absolute path it puts in a command, so turning
/// `'/` into `'<root>/` is enough.
private final class ShellExecDelegate: ExecDelegate {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func start(command: String, outputHandler: ExecOutputHandler) async throws -> ExecCommandContext {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.replacingOccurrences(of: "'/", with: "'\(root.path)/")]
        process.currentDirectoryURL = root
        process.standardInput = outputHandler.stdinPipe
        process.standardOutput = outputHandler.stdoutPipe
        process.standardError = outputHandler.stderrPipe
        let handler = UncheckedSendable(outputHandler)
        process.terminationHandler = { process in
            handler.value.succeed(exitCode: Int(process.terminationStatus))
        }
        try process.run()
        return ProcessContext(process: UncheckedSendable(process))
    }

    func setEnvironmentValue(_ value: String, forKey key: String) async throws {}

    private struct ProcessContext: ExecCommandContext {
        let process: UncheckedSendable<Process>

        func terminate() async throws {
            if process.value.isRunning { process.value.terminate() }
        }
    }
}

/// An interactive shell that prints a prompt and answers each line in capitals.
private struct ShoutingShell: ShellDelegate {
    func startShell(inbound: AsyncStream<ShellClientEvent>, outbound: ShellOutboundWriter, context: SSHShellContext) async throws {
        outbound.write("$ ")
        var line = ""
        for await event in inbound {
            guard case .stdin(let buffer) = event else { continue }
            for character in String(buffer: buffer) {
                if character == "\n" || character == "\r" {
                    if line == "exit" { return }
                    outbound.write(line.uppercased() + "\r\n$ ")
                    line = ""
                } else {
                    line.append(character)
                }
            }
        }
    }
}
