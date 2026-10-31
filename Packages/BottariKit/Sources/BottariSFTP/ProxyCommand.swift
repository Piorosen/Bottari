import BottariCore
import Foundation
import NIOCore
import NIOPosix
import Synchronization

/// A `ProxyCommand` running for one connection. Like `ssh`, Bottari starts the
/// command with a shell and speaks SSH over its standard input and output;
/// what it prints on standard error is kept to explain a failure.
final class ProxyCommand: Sendable {
    /// The program a command runs, and nothing after it: the rest may carry
    /// tokens or passwords (`--service-token-secret …`), which logs must not.
    static func program(of command: String) -> String {
        let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
        return (first as NSString).lastPathComponent + (command.contains(where: \.isWhitespace) ? " …" : "")
    }

    /// `command` with `ssh`'s tokens filled in: `%h` host, `%p` port, `%r`
    /// remote user, `%n` the name as typed, `%u` local user, `%d` home, `%%`.
    static func expand(_ command: String, for endpoint: SFTPEndpoint, alias: String) -> String {
        var out = ""
        var iterator = command.makeIterator()
        while let character = iterator.next() {
            guard character == "%", let token = iterator.next() else {
                out.append(character)
                continue
            }
            switch token {
            case "h": out += endpoint.host
            case "p": out += String(endpoint.port)
            case "r": out += endpoint.username
            case "n": out += alias
            case "u": out += NSUserName()
            case "d": out += UserHome.path
            case "%": out += "%"
            default: out += "%\(token)"
            }
        }
        return out
    }

    let command: String
    private let pid: pid_t
    private let errors = Mutex(Data())
    private let errorReader: FileHandle

    private init(command: String, pid: pid_t, errorReader: FileHandle) {
        self.command = command
        self.pid = pid
        self.errorReader = errorReader
    }

    /// The end of what the command printed on standard error.
    var errorOutput: String {
        String(decoding: errors.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts `command` and returns a channel over its standard input and
    /// output, with `prepare` run on it first. The command is stopped when the
    /// channel closes.
    static func start(
        _ command: String,
        group: any EventLoopGroup,
        prepare: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> (channel: any Channel, process: ProxyCommand) {
        // A command started from the App Sandbox stays in it, cut off from
        // ~/.ssh, Homebrew and the agent, and App Review does not allow it.
        if FolderAccess.isSandboxed {
            throw SFTPConnectError.proxyCommandFailed(command: command, reason: String(localized: "App Store 판은 macOS 샌드박스 안에서 실행되어 ProxyCommand를 쓸 수 없습니다. 연결 관리에서 점프 호스트(ProxyJump)로 바꾸십시오."))
        }
        var toCommand: [Int32] = [-1, -1]
        var fromCommand: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&toCommand) == 0, pipe(&fromCommand) == 0, pipe(&errorPipe) == 0 else {
            throw SFTPConnectError.proxyCommandFailed(command: command, reason: String(cString: strerror(errno)))
        }
        for fd in [toCommand[1], fromCommand[0], errorPipe[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toCommand[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromCommand[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], 2)
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the command, and it gets a
        // process group of its own so stopping it stops what it started.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let arguments = ["/bin/sh", "-c", "exec \(command)"]
        let environment = Self.environment().map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawned = withCStrings(arguments) { argv in
            withCStrings(environment) { envp in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
            }
        }
        close(toCommand[0])
        close(fromCommand[1])
        close(errorPipe[1])
        guard spawned == 0 else {
            close(toCommand[1])
            close(fromCommand[0])
            close(errorPipe[0])
            throw SFTPConnectError.proxyCommandFailed(command: command, reason: String(cString: strerror(spawned)))
        }

        Log.connection.info("ProxyCommand 실행 (pid \(pid)): \(Self.program(of: command))")
        let process = ProxyCommand(command: command, pid: pid, errorReader: FileHandle(fileDescriptor: errorPipe[0], closeOnDealloc: true))
        process.collectErrors()
        do {
            let channel = try await NIOPipeBootstrap(group: group)
                .channelInitializer(prepare)
                .takingOwnershipOfDescriptors(input: fromCommand[0], output: toCommand[1])
                .get()
            channel.closeFuture.whenComplete { _ in process.stop() }
            return (channel, process)
        } catch {
            process.stop()
            throw error
        }
    }

    private func collectErrors() {
        errorReader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.errors.withLock { errors in
                errors.append(data)
                if errors.count > 4096 { errors.removeFirst(errors.count - 4096) }
            }
        }
    }

    /// Stops the command and everything it started, and reaps it.
    func stop() {
        kill(-pid, SIGTERM)
        let pid = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    /// The app's environment, with the folders command-line tools usually live
    /// in added to PATH: an app started from the Dock gets only the system's.
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = UserHome.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"]
        let current = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        return environment
    }
}

/// Calls `body` with `strings` as a NULL-terminated C array.
private func withCStrings<T>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> T) -> T {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
