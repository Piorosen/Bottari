import Foundation
import NIOPosix
@testable import BottariSFTP

/// The Mac's own OpenSSH tools, for checking Bottari against the real thing
/// rather than Citadel's test server: `sshd` running as the current user on a
/// free port and `ssh-keygen` for keys.
enum OpenSSH {
    static let sshd = "/usr/sbin/sshd"
    static let keygen = "/usr/bin/ssh-keygen"

    static var isAvailable: Bool {
        [sshd, keygen].allSatisfy(FileManager.default.isExecutableFile(atPath:))
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

/// `sshd` as the current user, letting in the given public keys. `extraConfig`
/// comes first, so it can override a default (sshd keeps a keyword's first value).
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

    static func start(authorizing publicKeys: [String], extraConfig: [String] = [], ports: [Int] = (0..<5).map { _ in Int.random(in: 30000..<60000) }) async throws -> OpenSSHServer {
        let folder = try OpenSSH.scratch()
        let hostKey = folder.appending(path: "host_ed25519")
        try OpenSSH.run(OpenSSH.keygen, ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
        let authorized = folder.appending(path: "authorized_keys")
        try publicKeys.joined(separator: "\n").appending("\n").write(to: authorized, atomically: true, encoding: .utf8)
        var lastError: (any Error)?
        for port in ports {
            let config = folder.appending(path: "sshd_config")
            try (extraConfig + [
                "Port \(port)",
                "ListenAddress 127.0.0.1",
                "HostKey \(hostKey.path)",
                "AuthorizedKeysFile \(authorized.path)",
                "PidFile \(folder.appending(path: "sshd.pid").path)",
                "UsePAM no",
                "StrictModes no",
                "PasswordAuthentication no",
                "KbdInteractiveAuthentication no",
            ] + (extraConfig.contains { $0.hasPrefix("Subsystem") } ? [] : ["Subsystem sftp /usr/libexec/sftp-server"])).joined(separator: "\n").appending("\n").write(to: config, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: OpenSSH.sshd)
            process.arguments = ["-D", "-f", config.path, "-E", folder.appending(path: "sshd.log").path]
            let ended = try process.start()
            let server = OpenSSHServer(folder: folder, port: port, process: process, ended: ended)
            if await server.waitUntilListening() { return server }
            lastError = TestFailure("sshd did not start: \((try? String(contentsOf: folder.appending(path: "sshd.log"), encoding: .utf8)) ?? "")")
            process.stop(waitingOn: ended)
        }
        try? FileManager.default.removeItem(at: folder)
        throw lastError ?? TestFailure("sshd did not start")
    }

    private func waitUntilListening() async -> Bool {
        let log = folder.appending(path: "sshd.log")
        for _ in 0..<100 {
            guard process.isRunning else { return false }
            if let text = try? String(contentsOf: log, encoding: .utf8), text.contains("Server listening on 127.0.0.1 port \(port).") {
                return true
            }
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
