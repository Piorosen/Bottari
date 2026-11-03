import BottariCore
import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import BottariSFTP

/// Keys as `ssh-keygen` writes them, against `sshd` as it
/// ship with macOS. OpenSSH refuses RSA signed with SHA-1 since 8.8, which
/// Citadel's own RSA support still does.
@Suite(.enabled(if: OpenSSH.isAvailable), .timeLimit(.minutes(1)))
struct OpenSSHTests {
    // MARK: Reading key files

    @Test func aServerStartedOnATakenPortMovesToAnother() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let holderKey = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let ownKey = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let holder = try await OpenSSHServer.start(authorizing: [holderKey.publicKey])
        defer { holder.stop() }
        let server = try await OpenSSHServer.start(authorizing: [ownKey.publicKey], ports: [holder.port, holder.port + 1])
        defer { server.stop() }

        #expect(server.port != holder.port)
        let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(ownKey.privateKey), hostKeys: .acceptAnything)
        await provider.disconnect()
    }

    @Test(arguments: [
        ("ed25519", nil, nil),
        ("ecdsa", 256, "aes256-gcm@openssh.com"),
        ("ecdsa", 384, "aes128-cbc"),
        ("ecdsa", 521, nil),
        ("rsa", 2048, "aes256-ctr"),
    ] as [(String, Int?, String?)])
    func readsKeysWithTheirPassphrase(type: String, bits: Int?, cipher: String?) throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: type, bits: bits, passphrase: "correct horse", cipher: cipher)
        let file = try PrivateKeyFile(key.privateKey, passphrase: "correct horse")
        #expect(file.publicKeyBlob.base64EncodedString() == key.publicKey.split(separator: " ")[1])

        #expect(throws: SFTPConnectError.unreadableKey) { _ = try PrivateKeyFile(key.privateKey, passphrase: "wrong horse") }
        #expect(throws: SFTPConnectError.unreadableKey) { _ = try PrivateKeyFile(key.privateKey, passphrase: nil) }
    }

    @Test(arguments: [("rsa", 2048), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521)] as [(String, Int)])
    func readsUnencryptedPEMKeys(type: String, bits: Int) throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: type, bits: bits, pem: true)
        #expect(key.privateKey.hasPrefix("-----BEGIN \(type == "rsa" ? "RSA" : "EC") PRIVATE KEY-----"))
        let file = try PrivateKeyFile(key.privateKey, passphrase: nil)
        #expect(file.publicKeyBlob.base64EncodedString() == key.publicKey.split(separator: " ")[1])
    }

    @Test func bcryptMatchesTheReferenceVector() {
        // From OpenBSD's bcrypt_pbkdf regression test, as Go's x/crypto uses it.
        let key = BcryptPBKDF.derive(passphrase: Data("password".utf8), salt: Data("salt".utf8), rounds: 4, keyLength: 32)
        #expect(key?.map { String(format: "%02x", $0) }.joined() == "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9")
    }

    // MARK: Logging in

    @Test(arguments: [("rsa", 2048), ("ecdsa", 256), ("ecdsa", 521), ("ed25519", nil)] as [(String, Int?)])
    func logsInWithAKeyFile(type: String, bits: Int?) async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: type, bits: bits, passphrase: "pp")
        try await withServer(authorizing: [key.publicKey]) { server in
            let provider = try await SFTPFileProvider.connect(
                to: server.endpoint,
                credential: .privateKey(key.privateKey, passphrase: "pp"),
                hostKeys: .acceptAnything
            )
            #expect(provider.home.string == NSHomeDirectory())
            await provider.disconnect()
        }
    }

    /// Default keys are tried one by one until the server takes one.
    @Test func logsInWithWhicheverDefaultKeyTheServerKnows() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rsa = try OpenSSH.makeKey(in: folder, type: "rsa", bits: 2048)
        let ecdsa = try OpenSSH.makeKey(in: folder, type: "ecdsa", bits: 384)

        for key in [rsa, ecdsa] {
            try await withServer(authorizing: [key.publicKey]) { server in
                let provider = try await SFTPFileProvider.connect(
                    to: server.endpoint,
                    credential: .defaultKeys([rsa.privateKey, ecdsa.privateKey]),
                    hostKeys: .acceptAnything
                )
                #expect(try await provider.stat(RemotePath(NSHomeDirectory())).kind == .directory)
                await provider.disconnect()
            }
        }
    }

    @Test func aKeyTheServerDoesNotKnowIsRefused() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let known = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let stranger = try OpenSSH.makeKey(in: folder, type: "rsa", bits: 2048)
        try await withServer(authorizing: [known.publicKey]) { server in
            await #expect(throws: SFTPConnectError.authenticationFailed) {
                _ = try await SFTPFileProvider.connect(
                    to: server.endpoint,
                    credential: .privateKey(stranger.privateKey),
                    hostKeys: .acceptAnything
                )
            }
        }
    }

    /// sshd 9.8 and later punishes an address for each connection that ends in
    /// a refused login (PerSourcePenalties), so every way of logging in has to
    /// share one connection, as `ssh` does. The three default key files are
    /// five offers (RSA goes three ways) and leave room for a sixth within a
    /// stock MaxAuthTries.
    @Test func refusedDefaultKeysStillLeaveRoomForWhatComesAfter() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let known = try OpenSSH.makeKey(in: folder, type: "ed25519")
        try await withServer(authorizing: [known.publicKey], extraConfig: ["LogLevel VERBOSE"]) { server in
            let provider = try await SFTPFileProvider.connect(
                to: server.endpoint,
                credential: .fallback(.defaultKeys(try strangers(in: folder)), then: .privateKey(known.privateKey)),
                hostKeys: .acceptAnything
            )
            await provider.disconnect()
            #expect(!server.log.contains("penalty"), "sshd log:\n\(server.log)")
        }
    }

    /// With every default key refused, a wrong password is the sixth refusal,
    /// at which a stock sshd (MaxAuthTries 6) hangs up instead of answering.
    /// That is still a wrong password, not a server that takes no connections.
    @Test func aWrongPasswordAfterTheDefaultKeysIsStillAWrongPassword() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let known = try OpenSSH.makeKey(in: folder, type: "ed25519")
        try await withServer(authorizing: [known.publicKey], extraConfig: ["PasswordAuthentication yes", "LogLevel VERBOSE"]) { server in
            await #expect(throws: SFTPConnectError.authenticationFailed) {
                _ = try await SFTPFileProvider.connect(
                    to: server.endpoint,
                    credential: .fallback(.defaultKeys(try strangers(in: folder)), then: .password("wrong")),
                    hostKeys: .acceptAnything
                )
            }
            #expect(server.log.contains("Failed password for"), "sshd log:\n\(server.log)")
        }
    }

    /// An unknown key of each kind `SavedSite.defaultKeyFiles` names.
    private func strangers(in folder: URL) throws -> [String] {
        try [("ed25519", nil), ("ecdsa", 256), ("rsa", 2048)].map { type, bits in
            try OpenSSH.makeKey(in: folder, type: type, bits: bits).privateKey
        }
    }

    /// A password comes after the refused keys on the same connection, where
    /// the penalty for them cannot reach it. sshd as a plain user cannot check
    /// a password, but it logs the connection each refusal came on.
    @Test func thePasswordFollowsRefusedKeysOnTheSameConnection() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let known = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let stranger = try OpenSSH.makeKey(in: folder, type: "ed25519")
        try await withServer(authorizing: [known.publicKey], extraConfig: ["PasswordAuthentication yes", "LogLevel VERBOSE"]) { server in
            await #expect(throws: SFTPConnectError.authenticationFailed) {
                _ = try await SFTPFileProvider.connect(
                    to: server.endpoint,
                    credential: .fallback(.defaultKeys([stranger.privateKey]), then: .password("not checked")),
                    hostKeys: .acceptAnything
                )
            }
            func connections(refusing method: String) -> [Substring] {
                server.log.split(whereSeparator: \.isNewline).filter { $0.contains("Failed \(method) for") }.compactMap { line in
                    line.split(separator: " ").drop { $0 != "port" }.dropFirst().first
                }
            }
            let keyRefusals = connections(refusing: "publickey")
            #expect(keyRefusals.count == 1, "sshd log:\n\(server.log)")
            #expect(connections(refusing: "password") == keyRefusals, "sshd log:\n\(server.log)")
        }
    }

    @Test func permissionsLinksAndSearchOnARealServer() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let tree = RemotePath(folder.path).appending("tree")
        try FileManager.default.createDirectory(atPath: tree.appending("a dir/deep").string, withIntermediateDirectories: true)
        for name in ["top.log", "a dir/inner.LOG", "a dir/deep/last.log", "a dir/readme.md"] {
            FileManager.default.createFile(atPath: tree.appending(name).string, contents: Data("x".utf8))
        }
        try await withServer(authorizing: [key.publicKey]) { server in
            let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(key.privateKey), hostKeys: .acceptAnything)
            defer { Task { await provider.disconnect() } }
            #expect(provider.capabilities.isSuperset(of: [.permissions, .symbolicLinks]))

            let readme = tree.appending("a dir/readme.md")
            try await provider.setPermissions(0o640, at: readme)
            #expect(try await provider.stat(readme).permissions == 0o640)

            try await provider.makeSymbolicLink(at: tree.appending("shortcut"), to: "a dir")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tree.appending("shortcut").string) == "a dir")

            var found: [String: FileItem.Kind] = [:]
            for try await item in provider.search("log", in: tree, limit: 100) {
                found[String(item.path.string.dropFirst(tree.string.count + 1))] = item.kind
            }
            #expect(found == ["top.log": .file, "a dir/inner.LOG": .file, "a dir/deep/last.log": .file])
            var dirs: [String] = []
            for try await item in provider.search("*dir", in: tree, limit: 100) where item.kind == .directory {
                dirs.append(item.name)
            }
            // The link to the folder is not a folder of its own.
            #expect(dirs == ["a dir"])
        }
    }

    @Test func savingThroughALinkAndInAFolderThatCannotBeWritten() async throws {
        let folder = try OpenSSH.scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "locked").path)
            try? FileManager.default.removeItem(at: folder)
        }
        let key = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appending(path: "sites-available"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appending(path: "sites-enabled"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appending(path: "sites-available/default"))
        try fm.createSymbolicLink(atPath: folder.appending(path: "sites-enabled/default").path, withDestinationPath: "../sites-available/default")
        try fm.createDirectory(at: folder.appending(path: "locked"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appending(path: "locked/app.conf"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.appending(path: "locked").path)

        try await withServer(authorizing: [key.publicKey]) { server in
            let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(key.privateKey), hostKeys: .acceptAnything)
            defer { Task { await provider.disconnect() } }

            try await provider.write(RemotePath(folder.appending(path: "sites-enabled/default").path), data: Data("new".utf8))
            // The link is still a link, and the file it points to has the new text.
            #expect(try fm.destinationOfSymbolicLink(atPath: folder.appending(path: "sites-enabled/default").path) == "../sites-available/default")
            #expect(try String(contentsOf: folder.appending(path: "sites-available/default"), encoding: .utf8) == "new")

            try await provider.write(RemotePath(folder.appending(path: "locked/app.conf").path), data: Data("new".utf8))
            #expect(try String(contentsOf: folder.appending(path: "locked/app.conf"), encoding: .utf8) == "new")
        }
    }

    @Test func aLinkThatCannotBeDeletedLeavesWhatItPointsTo() async throws {
        let folder = try OpenSSH.scratch()
        let fm = FileManager.default
        let locked = folder.appending(path: "locked")
        let kept = folder.appending(path: "project/keep.txt")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: folder)
        }
        let key = try OpenSSH.makeKey(in: folder, type: "ed25519")
        try fm.createDirectory(at: folder.appending(path: "project"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: kept)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: locked.appending(path: "ext").path, withDestinationPath: "../project")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        try await withServer(authorizing: [key.publicKey]) { server in
            let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(key.privateKey), hostKeys: .acceptAnything)
            defer { Task { await provider.disconnect() } }
            let lockedPath = RemotePath(locked.path)

            await #expect(throws: ProviderError.permissionDenied(lockedPath.appending("ext"))) {
                try await provider.delete(lockedPath.appending("ext"))
            }
            #expect((try? String(contentsOf: kept, encoding: .utf8)) == "keep")
            await #expect(throws: ProviderError.permissionDenied(lockedPath.appending("ext"))) {
                try await provider.delete(lockedPath)
            }
            #expect((try? String(contentsOf: kept, encoding: .utf8)) == "keep")
            #expect((try? fm.destinationOfSymbolicLink(atPath: locked.appending(path: "ext").path)) == "../project")

            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try await provider.delete(lockedPath)
            #expect(!fm.fileExists(atPath: locked.path))
            #expect((try? String(contentsOf: kept, encoding: .utf8)) == "keep")
        }
    }

    @Test func aLinkPlantedAtThePartialNameIsNotWrittenThrough() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let fm = FileManager.default
        let shared = RemotePath(folder.path).appending("shared")
        let victim = URL(fileURLWithPath: shared.appending("victim.txt").string)
        try fm.createDirectory(atPath: shared.string, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim)
        let upload = shared.appending("up.txt")
        let resumed = shared.appending("resumed.txt")
        for path in [upload, resumed] {
            try fm.createSymbolicLink(atPath: path.partialWritePath.string, withDestinationPath: "victim.txt")
        }

        try await withServer(authorizing: [key.publicKey]) { server in
            let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(key.privateKey), hostKeys: .acceptAnything)
            defer { Task { await provider.disconnect() } }

            try await provider.write(upload, data: Data("new".utf8))
            #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
            #expect(try String(contentsOf: URL(fileURLWithPath: upload.string), encoding: .utf8) == "new")
            #expect((try? fm.destinationOfSymbolicLink(atPath: upload.string)) == nil)

            await #expect(throws: (any Error).self) {
                try await provider.write(resumed, from: AsyncThrowingStream { continuation in
                    continuation.yield(Data("23".utf8))
                    continuation.finish()
                }, resumingAt: 2)
            }
            #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
        }
    }

    @Test func aNameNearTheLimitCanStillBeUploadedAndReplaced() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let tree = RemotePath(folder.path).appending("tree")
        try FileManager.default.createDirectory(atPath: tree.string, withIntermediateDirectories: true)
        let name = String(repeating: "a", count: FileNames.maxNameBytes - 5) + ".txt"
        let file = tree.appending(name)

        try await withServer(authorizing: [key.publicKey]) { server in
            let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(key.privateKey), hostKeys: .acceptAnything)
            defer { Task { await provider.disconnect() } }

            try await provider.write(file, data: Data("x".utf8))
            try await provider.write(file, data: Data("y".utf8))

            #expect(try String(contentsOf: URL(fileURLWithPath: file.string), encoding: .utf8) == "y")
            #expect(try FileManager.default.contentsOfDirectory(atPath: tree.string) == [name])
        }
    }

    @Test func aFolderAsSFTPShowsItIsFoundForTheShell() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: "ed25519")
        // A NAS: SFTP shows "/my share/it's", the shell finds it under a volume.
        let volume = folder.appending(path: "vol1")
        try FileManager.default.createDirectory(at: volume.appending(path: "my share/it's"), withIntermediateDirectories: true)
        let bases = [folder.path + "/vol[0-9]*"]
        try await withServer(authorizing: [key.publicKey]) { server in
            let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(key.privateKey), hostKeys: .acceptAnything)
            defer { Task { await provider.disconnect() } }
            let onVolume = try await provider.run(SFTPFileProvider.shellPathScript(for: "/my share/it's", bases: bases))
            #expect(onVolume == volume.path + "/my share/it's\n")
            // A path the shell sees as it is stays as it is.
            let direct = try await provider.run(SFTPFileProvider.shellPathScript(for: RemotePath(volume.path), bases: bases))
            #expect(direct == volume.path + "\n")
            // Nowhere at all: nothing.
            let missing = try await provider.run(SFTPFileProvider.shellPathScript(for: "/nowhere", bases: bases))
            #expect(missing.isEmpty)
        }
    }

    @Test func listingsDoNotLeaveHandlesOpen() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: "ed25519")
        // sftp-server keeps each open directory as a file descriptor; here it
        // gets 64 of them, as a busy server might have left.
        try await withServer(authorizing: [key.publicKey], extraConfig: ["Subsystem sftp ulimit -n 64; exec /usr/libexec/sftp-server"]) { server in
            let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(key.privateKey), hostKeys: .acceptAnything)
            defer { Task { await provider.disconnect() } }
            for _ in 0..<200 {
                _ = try await provider.list(RemotePath(folder.path))
            }
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/tcsh")))
    func commandsRunTheSameForAnAccountWhoseShellIsTcsh() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let odd = folder.appending(path: "it's \"odd\" $HOME !x \\y\nz.txt")
        try Data("odd\n".utf8).write(to: odd)
        // sshd runs a command with the account's login shell and -c, here tcsh's.
        try await withServer(authorizing: [key.publicKey], extraConfig: ["ForceCommand exec /bin/tcsh -f -c \"$SSH_ORIGINAL_COMMAND\""]) { server in
            let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(key.privateKey), hostKeys: .acceptAnything)
            defer { Task { await provider.disconnect() } }
            #expect(provider.canRunCommands)

            let keys = folder.appending(path: "new .ssh/authorized_keys")
            try await provider.authorize(publicKey: key.publicKey, in: keys.path)
            #expect(try String(contentsOf: keys, encoding: .utf8) == key.publicKey + "\n")

            let copy = RemotePath(folder.path).appending("copy of " + odd.lastPathComponent)
            try await provider.copy(RemotePath(odd.path), to: copy)
            #expect(try String(contentsOfFile: copy.string, encoding: .utf8) == "odd\n")
            #expect(try await provider.checksum(copy) == "80a3ef2f5539b0a6b5ee045e2a1de83bfb38550da54aa4d60dc1b9526b4b0805")
        }
    }

    // MARK: Agent forwarding

    @Test func aCommandCanUseTheForwardedAgent() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let login = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let forwardedFile = try OpenSSH.makeKey(in: folder, type: "ecdsa", bits: 256)
        try await withServer(authorizing: [login.publicKey], extraConfig: ["AllowAgentForwarding yes"]) { server in
            let connection = try await SFTPConnection.open(to: server.endpoint, credential: .privateKey(login.privateKey), hostKeys: .acceptAnything)
            defer { Task { await connection.close() } }

            // Keys Bottari read from a file, signed for by Bottari itself.
            let listed = try await connection.run("ssh-add -L", forwarding: .keys([try PrivateKeyFile(forwardedFile.privateKey, passphrase: nil)]))
            #expect(listed.exitStatus == 0, "\(listed.errors)")
            #expect(listed.output.contains(forwardedFile.publicKey.split(separator: " ")[1]))

            // Without forwarding the session sees no agent.
            let none = try await connection.run("ssh-add -L; echo \"status $?\"", forwarding: .keys([]))
            #expect(none.output.contains("The agent has no identities") || none.output.contains("status 1"))
        }
    }

    // MARK: Checking a port before a remote screen

    @Test func tellsAnsweringFromSilentFromForwardingTurnedOff() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let login = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let listening = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        defer { listening.close(promise: nil) }
        let closed = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let closedPort = closed.localAddress!.port!
        try await closed.close()

        try await withServer(authorizing: [login.publicKey], extraConfig: ["AllowTcpForwarding yes"]) { server in
            let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(login.privateKey), hostKeys: .acceptAnything)
            #expect(await provider.checkPort(host: "127.0.0.1", port: listening.localAddress!.port!) == .answering)
            #expect(await provider.checkPort(host: "127.0.0.1", port: closedPort) == .silent)
            #expect(await provider.checkPort(host: "127.0.0.1", port: 0) == .silent)
            await provider.disconnect()
        }
        try await withServer(authorizing: [login.publicKey], extraConfig: ["AllowTcpForwarding no"]) { server in
            let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(login.privateKey), hostKeys: .acceptAnything)
            #expect(await provider.checkPort(host: "127.0.0.1", port: listening.localAddress!.port!) == .forwardingDisabled)
            await provider.disconnect()
        }
    }

    // MARK: Server to server

    @Test(arguments: [false, true])
    func oneServerSendsStraightToAnother(withDefaultKeys: Bool) async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceLogin = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let destinationLogin = try OpenSSH.makeKey(in: folder, type: "ecdsa", bits: 256)
        let tree = RemotePath(folder.path)
        try FileManager.default.createDirectory(atPath: tree.appending("from/site/img").string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tree.appending("to").string, withIntermediateDirectories: true)
        try "<h1>hi</h1>".write(toFile: tree.appending("from/site/index.html").string, atomically: true, encoding: .utf8)
        try Data(repeating: 7, count: 300_000).write(to: URL(fileURLWithPath: tree.appending("from/site/img/big.bin").string))
        try "notes".write(toFile: tree.appending("from/notes 1.txt").string, atomically: true, encoding: .utf8)

        let source = try await OpenSSHServer.start(authorizing: [sourceLogin.publicKey])
        defer { source.stop() }
        let destination = try await OpenSSHServer.start(authorizing: [destinationLogin.publicKey])
        defer { destination.stop() }
        let knownHosts = KnownHosts(fileURL: nil)
        let from = try await SFTPFileProvider.connect(to: source.endpoint, credential: .privateKey(sourceLogin.privateKey), hostKeys: .knownHosts(knownHosts))
        let to = try await SFTPFileProvider.connect(
            to: destination.endpoint,
            credential: withDefaultKeys ? .defaultKeys([destinationLogin.privateKey]) : .privateKey(destinationLogin.privateKey),
            hostKeys: .knownHosts(knownHosts)
        )
        #expect(from.canSend(directlyTo: to))

        let items = try await from.list(tree.appending("from"))
        try await from.send(items, directlyTo: to, into: tree.appending("to"))

        #expect(try String(contentsOfFile: tree.appending("to/site/index.html").string, encoding: .utf8) == "<h1>hi</h1>")
        #expect(try Data(contentsOf: URL(fileURLWithPath: tree.appending("to/site/img/big.bin").string)) == Data(repeating: 7, count: 300_000))
        #expect(try String(contentsOfFile: tree.appending("to/notes 1.txt").string, encoding: .utf8) == "notes")

        // With the destination gone, the source says it cannot get there.
        destination.stop()
        await #expect {
            try await from.send(items, directlyTo: to, into: tree.appending("to"))
        } throws: { error in
            if case DirectCopyError.unreachable = error { return true }
            return false
        }
        await from.disconnect()
        await to.disconnect()
    }

    @Test func aServerSendsStraightToAnotherThroughAJumpHost() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceLogin = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let login = try OpenSSH.makeKey(in: folder, type: "ecdsa", bits: 256)
        let tree = RemotePath(folder.path)
        try FileManager.default.createDirectory(atPath: tree.appending("from").string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tree.appending("to").string, withIntermediateDirectories: true)
        try "via the bastion".write(toFile: tree.appending("from/note.txt").string, atomically: true, encoding: .utf8)

        let source = try await OpenSSHServer.start(authorizing: [sourceLogin.publicKey])
        defer { source.stop() }
        let jump = try await OpenSSHServer.start(authorizing: [login.publicKey])
        defer { jump.stop() }
        let destination = try await OpenSSHServer.start(authorizing: [login.publicKey])
        defer { destination.stop() }
        let knownHosts = KnownHosts(fileURL: nil)
        let from = try await SFTPFileProvider.connect(to: source.endpoint, credential: .privateKey(sourceLogin.privateKey), hostKeys: .knownHosts(knownHosts))
        let to = try await SFTPFileProvider.connect(
            to: destination.endpoint,
            credential: .privateKey(login.privateKey),
            hostKeys: .knownHosts(knownHosts),
            via: [SSHHop(endpoint: jump.endpoint, credential: .privateKey(login.privateKey))]
        )
        #expect(from.canSend(directlyTo: to))

        try await from.send(try await from.list(tree.appending("from")), directlyTo: to, into: tree.appending("to"))
        #expect(try String(contentsOfFile: tree.appending("to/note.txt").string, encoding: .utf8) == "via the bastion")
        await from.disconnect()
        await to.disconnect()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/tcsh")), arguments: [(true, false), (false, true)])
    func serversWhoseShellIsTcshSendStraightToEachOther(sourceTcsh: Bool, destinationTcsh: Bool) async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceLogin = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let destinationLogin = try OpenSSH.makeKey(in: folder, type: "ecdsa", bits: 256)
        let tree = RemotePath(folder.path)
        try FileManager.default.createDirectory(atPath: tree.appending("from").string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tree.appending("to !it's").string, withIntermediateDirectories: true)
        try "wow".write(toFile: tree.appending("from/wow!.txt").string, atomically: true, encoding: .utf8)

        let tcsh = ["ForceCommand exec /bin/tcsh -f -c \"$SSH_ORIGINAL_COMMAND\""]
        let source = try await OpenSSHServer.start(authorizing: [sourceLogin.publicKey], extraConfig: sourceTcsh ? tcsh : [])
        defer { source.stop() }
        let destination = try await OpenSSHServer.start(authorizing: [destinationLogin.publicKey], extraConfig: destinationTcsh ? tcsh : [])
        defer { destination.stop() }
        let knownHosts = KnownHosts(fileURL: nil)
        let from = try await SFTPFileProvider.connect(to: source.endpoint, credential: .privateKey(sourceLogin.privateKey), hostKeys: .knownHosts(knownHosts))
        let to = try await SFTPFileProvider.connect(to: destination.endpoint, credential: .privateKey(destinationLogin.privateKey), hostKeys: .knownHosts(knownHosts))
        defer { Task { await from.disconnect(); await to.disconnect() } }
        #expect(from.canSend(directlyTo: to))

        try await from.send(try await from.list(tree.appending("from")), directlyTo: to, into: tree.appending("to !it's"))
        #expect(try String(contentsOfFile: tree.appending("to !it's/wow!.txt").string, encoding: .utf8) == "wow")
    }

    @Test func nestedProxyCommandsExpandTokensAtTheirOwnLevel() {
        let target = SFTPEndpoint(host: "db", port: 5432, username: "me")
        let hops = [SFTPEndpoint(host: "edge", username: "me"), SFTPEndpoint(host: "inner", username: "me")]
        let command = SFTPFileProvider.sshCommand(to: target, through: hops, checkingKeys: true)
        // The ssh to inner expands %h once; the ProxyCommand reaching edge, inside it, waits a level.
        #expect(command.contains("-W %%h:%%p"))
        #expect(command.contains(" -W %h:%p"))
        #expect(!command.contains("-J"))
    }

    @Test func passwordLoginsCannotBeLentToAnotherServer() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let login = try OpenSSH.makeKey(in: folder, type: "ed25519")
        try await withServer(authorizing: [login.publicKey]) { server in
            let keyed = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(login.privateKey), hostKeys: .acceptAnything)
            let withPassword = try await SFTPFileProvider.connect(
                to: server.endpoint,
                credential: .fallback(.privateKey(login.privateKey), then: .password("unused")),
                hostKeys: .acceptAnything
            )
            #expect(DirectReach(endpoint: server.endpoint, credential: .password("pw"), hops: [], hostKeys: .acceptAnything) == nil)
            // The same server is never a destination for itself.
            #expect(!keyed.canSend(directlyTo: withPassword))
            await keyed.disconnect()
            await withPassword.disconnect()
        }
    }

    private func withServer(authorizing keys: [String], extraConfig: [String] = [], _ body: (OpenSSHServer) async throws -> Void) async throws {
        let server = try await OpenSSHServer.start(authorizing: keys, extraConfig: extraConfig)
        defer { server.stop() }
        do {
            try await body(server)
        } catch {
            Issue.record("sshd log:\n\(server.log)")
            throw error
        }
    }
}
