import Foundation
import NIOPosix
@testable import BottariSFTP

/// The Mac's own OpenSSH tools, for checking Bottari against the real thing
/// rather than Citadel's test server: `sshd` running as the current user on a
/// free port, `ssh-keygen` for keys and `ssh-agent` for an agent.
enum OpenSSH {
    static let sshd = "/usr/sbin/sshd"
    static let keygen = "/usr/bin/ssh-keygen"
    static let agent = "/usr/bin/ssh-agent"
    static let add = "/usr/bin/ssh-add"

    static var isAvailable: Bool {
        [sshd, keygen, agent, add].allSatisfy(FileManager.default.isExecutableFile(atPath:))
    }

    /// A fresh scratch folder, with a name short enough for a Unix socket path inside.
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs a tool to completion, failing on a nonzero exit.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let ended = try process.start()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ended.wait()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw TestFailure("\(tool) \(arguments.joined(separator: " ")) failed: \(text)")
        }
        return text
    }

    /// A new key pair from `ssh-keygen`: the private key file's text and the public key line.
    static func makeKey(
        in folder: URL,
        type: String,
        bits: Int? = nil,
        passphrase: String = "",
        cipher: String? = nil,
        pem: Bool = false
    ) throws -> (path: URL, privateKey: String, publicKey: String) {
        let path = folder.appending(path: "\(type)-\(UUID().uuidString.prefix(6))")
        var arguments = ["-q", "-t", type, "-N", passphrase, "-C", "", "-a", "2", "-f", path.path]
        if let bits { arguments += ["-b", String(bits)] }
        if let cipher { arguments += ["-Z", cipher] }
        if pem { arguments += ["-m", "PEM"] }
        try run(keygen, arguments)
        return (
            path,
            try String(contentsOf: path, encoding: .utf8),
            try String(contentsOf: path.appendingPathExtension("pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `sshd` as the current user, letting in the given public keys.
final class OpenSSHServer {
    let folder: URL
    let port: Int
    private let process: Process
    private let ended: DispatchSemaphore
    private var stopped = false

    var endpoint: SFTPEndpoint {
        SFTPEndpoint(host: "127.0.0.1", port: port, username: NSUserName())
    }

    private init(folder: URL, port: Int, process: Process, ended: DispatchSemaphore) {
        self.folder = folder
        self.port = port
        self.process = process
        self.ended = ended
    }

    static func start(authorizing publicKeys: [String], extraConfig: [String] = []) async throws -> OpenSSHServer {
        let folder = try OpenSSH.scratch()
        let hostKey = folder.appending(path: "host_ed25519")
        try OpenSSH.run(OpenSSH.keygen, ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
        let authorized = folder.appending(path: "authorized_keys")
        try publicKeys.joined(separator: "\n").appending("\n").write(to: authorized, atomically: true, encoding: .utf8)
        var lastError: (any Error)?
        for _ in 0..<5 {
            let port = Int.random(in: 30000..<60000)
            let config = folder.appending(path: "sshd_config")
            try ([
                "Port \(port)",
                "ListenAddress 127.0.0.1",
                "HostKey \(hostKey.path)",
                "AuthorizedKeysFile \(authorized.path)",
                "PidFile \(folder.appending(path: "sshd.pid").path)",
                "UsePAM no",
                "StrictModes no",
                "PasswordAuthentication no",
                "KbdInteractiveAuthentication no",
                "Subsystem sftp /usr/libexec/sftp-server",
            ] + extraConfig).joined(separator: "\n").appending("\n").write(to: config, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: OpenSSH.sshd)
            process.arguments = ["-D", "-f", config.path, "-E", folder.appending(path: "sshd.log").path]
            let server = OpenSSHServer(folder: folder, port: port, process: process, ended: try process.start())
            if await server.waitUntilListening() { return server }
            lastError = TestFailure("sshd did not start: \((try? String(contentsOf: folder.appending(path: "sshd.log"), encoding: .utf8)) ?? "")")
            server.stop()
        }
        throw lastError ?? TestFailure("sshd did not start")
    }

    private func waitUntilListening() async -> Bool {
        for _ in 0..<50 {
            guard process.isRunning else { return false }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(fd)
            if connected == 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// What sshd logged, for a failing test to show.
    var log: String {
        (try? String(contentsOf: folder.appending(path: "sshd.log"), encoding: .utf8)) ?? ""
    }

    /// Stops sshd; calling it again does nothing.
    func stop() {
        guard !stopped else { return }
        stopped = true
        process.stop(waitingOn: ended)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// `ssh-agent` on a socket of its own, holding the given key files.
final class OpenSSHAgent {
    let socket: String
    private let folder: URL
    private let process: Process
    private let ended: DispatchSemaphore

    init(adding keyFiles: [URL]) throws {
        folder = try OpenSSH.scratch()
        socket = folder.appending(path: "agent.sock").path
        process = Process()
        process.executableURL = URL(fileURLWithPath: OpenSSH.agent)
        process.arguments = ["-D", "-a", socket]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        ended = try process.start()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) {
            usleep(20_000)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = socket
        for file in keyFiles {
            try OpenSSH.run(OpenSSH.add, ["-q", file.path], environment: environment)
        }
    }

    func stop() {
        process.stop(waitingOn: ended)
        try? FileManager.default.removeItem(at: folder)
    }
}
