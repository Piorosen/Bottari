import BottariCore
import Foundation
import Testing
@testable import BottariSFTP

/// Keys as `ssh-keygen` writes them, against `sshd` and `ssh-agent` as they
/// ship with macOS. OpenSSH refuses RSA signed with SHA-1 since 8.8, which
/// Citadel's own RSA support still does.
@Suite(.enabled(if: OpenSSH.isAvailable), .timeLimit(.minutes(1)))
struct OpenSSHTests {
    // MARK: Reading key files

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

    @Test func logsInWithTheAgentsRSAAndECDSAKeys() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rsa = try OpenSSH.makeKey(in: folder, type: "rsa", bits: 2048)
        let ecdsa = try OpenSSH.makeKey(in: folder, type: "ecdsa", bits: 384)
        let agent = try OpenSSHAgent(adding: [rsa.path, ecdsa.path])
        defer { agent.stop() }

        for key in [rsa, ecdsa] {
            try await withServer(authorizing: [key.publicKey]) { server in
                let provider = try await SFTPFileProvider.connect(
                    to: server.endpoint,
                    credential: .agent(socket: agent.socket),
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

    private func withServer(authorizing keys: [String], _ body: (OpenSSHServer) async throws -> Void) async throws {
        let server = try await OpenSSHServer.start(authorizing: keys)
        defer { server.stop() }
        do {
            try await body(server)
        } catch {
            Issue.record("sshd log:\n\(server.log)")
            throw error
        }
    }
}
