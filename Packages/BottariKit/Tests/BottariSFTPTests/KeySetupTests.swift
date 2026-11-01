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
        await withKey.disconnect()
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
}
