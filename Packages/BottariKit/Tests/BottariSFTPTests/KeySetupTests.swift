import BottariCore
import Foundation
import Testing
@testable import BottariSFTP

/// Keys Bottari makes, and putting them on a server in place of a password.
@Suite(.enabled(if: OpenSSH.isAvailable), .timeLimit(.minutes(1)))
struct KeySetupTests {
    /// OpenSSH reads the private key and finds the same public key in it.
    @Test(arguments: NewSSHKey.Kind.allCases)
    func newKeysAreWhatSshKeygenWrites(kind: NewSSHKey.Kind) throws {
        let key = try NewSSHKey.generate(kind, comment: "bottari@test")
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "id")
        try key.privateKey.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let derived = try OpenSSH.run(OpenSSH.keygen, ["-y", "-f", file.path]).split(separator: " ").prefix(2)
        #expect(Array(derived) == Array(key.publicKey.split(separator: " ").prefix(2)))
        #expect(key.publicKey.hasSuffix(" bottari@test"))
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        // And Bottari reads it back.
        #expect((try PrivateKeyFile(key.privateKey, passphrase: nil)).publicKeyLine(comment: "bottari@test") == key.publicKey)
    }

    /// Logged in with what it has now, Bottari puts the new key in
    /// authorized_keys once, and the key alone gets in afterwards.
    @Test(arguments: NewSSHKey.Kind.allCases)
    func aKeyPutOnTheServerLogsIn(kind: NewSSHKey.Kind) async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let fresh = try NewSSHKey.generate(kind, comment: "bottari@test")
        let server = try await OpenSSHServer.start(authorizing: [current.publicKey])
        defer { server.stop() }
        let authorized = server.folder.appending(path: "authorized_keys")

        await #expect(throws: SFTPConnectError.authenticationFailed) {
            _ = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(fresh.privateKey), hostKeys: .acceptAnything)
        }
        let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(current.privateKey), hostKeys: .acceptAnything)
        try await provider.authorize(publicKey: fresh.publicKey, in: authorized.path)
        try await provider.authorize(publicKey: fresh.publicKey, in: authorized.path)
        await provider.disconnect()

        let lines = try String(contentsOf: authorized, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [current.publicKey, fresh.publicKey])
        let withKey = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(fresh.privateKey), hostKeys: .acceptAnything)
        #expect(try await withKey.stat(RemotePath(NSHomeDirectory())).kind == .directory)

        // Taken off again (a connection deleted): matched on the key, not the comment.
        let renamed = fresh.publicKey.replacingOccurrences(of: "bottari@test", with: "someone@else")
        try await withKey.unauthorize(publicKey: renamed, in: authorized.path)
        await withKey.disconnect()
        #expect(try String(contentsOf: authorized, encoding: .utf8).split(separator: "\n").map(String.init) == [current.publicKey])
        await #expect(throws: SFTPConnectError.authenticationFailed) {
            _ = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(fresh.privateKey), hostKeys: .acceptAnything)
        }
    }

    /// A new key for a site takes the key Bottari made for it before off the
    /// server, once the new one is known to log in. A key the user brought in
    /// from a key file of their own stays on the server.
    @Test func aNewKeyRetiresTheOneBottariMadeBefore() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let server = try await OpenSSHServer.start(authorizing: [own.publicKey])
        defer { server.stop() }
        let authorized = server.folder.appending(path: "authorized_keys")
        let site = SavedSite(name: "box", endpoint: server.endpoint, authentication: .storedKey)
        let secrets = InMemorySecretStore()
        func connect(_ site: SavedSite, _ typed: TypedSecrets) async throws -> SFTPFileProvider {
            let plan = try site.connectionPlan(sites: [], sshConfig: SSHConfig(text: "", directory: ""), secrets: typed.over(secrets))
            return try await SFTPFileProvider.connect(to: plan.endpoint, credential: plan.credential, hostKeys: .acceptAnything, via: plan.hops)
        }
        // As the app does it: the key Bottari keeps for the site is replaced
        // once the new one is in and checked.
        func switchToNewKey() async throws -> NewSSHKey {
            let key = try NewSSHKey.generate(.ed25519, comment: "bottari@test")
            let previous = try secrets.secret(for: site.privateKeyKey).flatMap { NewSSHKey(privateKey: $0) }
            try await site.install(key, replacing: previous, over: nil, typed: TypedSecrets(), in: authorized.path, connect: connect) { _ in }
            try secrets.setSecret(key.privateKey, for: site.privateKeyKey)
            return key
        }
        // The user's own key, copied into the Keychain from ~/.ssh.
        try secrets.setSecret(own.privateKey, for: site.privateKeyKey)

        let first = try await switchToNewKey()
        let second = try await switchToNewKey()

        let lines = try String(contentsOf: authorized, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [own.publicKey, second.publicKey])
        await #expect(throws: SFTPConnectError.authenticationFailed) {
            _ = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(first.privateKey), hostKeys: .acceptAnything)
        }
    }

    /// Behind a jump host whose password was typed and not saved, the new
    /// key is checked through that jump host with the typed password.
    @Test func aNewKeyIsCheckedThroughAJumpHostWithItsTypedPassword() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let server = try await OpenSSHServer.start(authorizing: [own.publicKey])
        defer { server.stop() }
        let jump = try await TestSFTPServer.start(forwarding: true)
        let bastion = SavedSite(name: "bastion", endpoint: jump.endpoint, authentication: .password)
        let site = SavedSite(name: "box", endpoint: server.endpoint, authentication: .storedKey, proxyJump: ["bastion"])
        let secrets = InMemorySecretStore([site.privateKeyKey: own.privateKey])
        func connect(_ site: SavedSite, _ typed: TypedSecrets) async throws -> SFTPFileProvider {
            let plan = try site.connectionPlan(sites: [bastion, site], sshConfig: SSHConfig(text: "", directory: ""), secrets: typed.over(secrets))
            return try await SFTPFileProvider.connect(to: plan.endpoint, credential: plan.credential, hostKeys: .acceptAnything, via: plan.hops)
        }
        var typed = TypedSecrets()
        typed.set(TestSFTPServer.password, for: bastion.passwordKey, keeping: false)
        let key = try NewSSHKey.generate(.ed25519, comment: "bottari@test")
        let authorized = server.folder.appending(path: "authorized_keys")

        let installed = await Result { try await site.install(key, replacing: nil, over: nil, typed: typed, in: authorized.path, connect: connect) { _ in } }
        await jump.stop()

        #expect(throws: Never.self) { try installed.get() }
        #expect(try String(contentsOf: authorized, encoding: .utf8).split(separator: "\n").map(String.init) == [own.publicKey, key.publicKey])
    }

    /// Some servers and appliances take RSA only with SHA-256.
    @Test func rsaKeysAlsoSignWithSHA256() async throws {
        let key = try NewSSHKey.generate(.rsa, comment: "bottari@test")
        let server = try await OpenSSHServer.start(authorizing: [key.publicKey], extraConfig: ["PubkeyAcceptedAlgorithms rsa-sha2-256"])
        defer { server.stop() }
        let provider = try await SFTPFileProvider.connect(to: server.endpoint, credential: .privateKey(key.privateKey), hostKeys: .acceptAnything)
        #expect(try await provider.stat(RemotePath(NSHomeDirectory())).kind == .directory)
        await provider.disconnect()
    }

    /// Before importing, a key file shows its type and fingerprint, even
    /// behind a passphrase, as `ssh-keygen -l` would.
    @Test func keyFilesDescribeThemselvesWithoutTheirPassphrase() throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (type, passphrase) in [("ed25519", "secret"), ("rsa", ""), ("ecdsa", "")] {
            let key = try OpenSSH.makeKey(in: folder, type: type, bits: type == "rsa" ? 2048 : nil, passphrase: passphrase)
            let listed = try OpenSSH.run(OpenSSH.keygen, ["-l", "-f", key.path.path + ".pub"]).split(separator: " ")
            let summary = try #require(SSHKeyFileSummary(keyText: key.privateKey))
            #expect(summary.fingerprint == String(listed[1]))
            #expect(summary.isEncrypted == !passphrase.isEmpty)
            #expect(summary.type == String(key.publicKey.split(separator: " ")[0]))
        }
        #expect(SSHKeyFileSummary(keyText: "Host prod\n  HostName example.com") == nil)
    }
}
