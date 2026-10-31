import Foundation
import Testing
@testable import BottariSFTP

@Suite struct KnownHostsTests {
    let ed = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJUWyugmFkYNkI42a2zPaqZFqHAd2E7Fp3yB3S9WlD1u"
    let otherEd = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOm3XhEo/fhAPoTUKlPQKZv7oNFzxk1+ehmgqmkdLnXh"
    let ecdsa = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBA=="

    @Test func plainPatternsWildcardsNegationAndPorts() {
        let list = OpenSSHKnownHosts(text: """
        # comment
        prod.example.com,10.0.0.5 \(ed)
        *.internal,!secret.internal \(ed)
        [nas.local]:2222 \(ed) my nas
        """)
        #expect(list.verdict(for: ed, host: "prod.example.com") == .trusted)
        #expect(list.verdict(for: ed, host: "PROD.example.com") == .trusted)
        #expect(list.verdict(for: ed, host: "10.0.0.5") == .trusted)
        #expect(list.verdict(for: ed, host: "db.internal") == .trusted)
        #expect(list.verdict(for: ed, host: "secret.internal") == .unknown)
        #expect(list.verdict(for: ed, host: "[nas.local]:2222") == .trusted)
        #expect(list.verdict(for: ed, host: "nas.local") == .unknown)
        #expect(list.verdict(for: otherEd, host: "prod.example.com") == .changed(expected: ed))
        // A key of another kind cannot be vouched for, only noted.
        #expect(list.verdict(for: ecdsa, host: "prod.example.com") == .otherKinds(known: [ed]))
    }

    @Test func revokedKeysAndCertificateAuthorities() {
        let list = OpenSSHKnownHosts(text: """
        @revoked * \(otherEd)
        @cert-authority *.example.com \(ed)
        """)
        #expect(list.verdict(for: otherEd, host: "anything") == .revoked)
        #expect(list.verdict(for: ed, host: "web.example.com") == .unknown)
    }

    @Test(.enabled(if: OpenSSH.isAvailable)) func hashedNamesAsSSHKeygenWritesThem() throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "known_hosts")
        try "prod.example.com \(ed)\n[nas.local]:2222 \(ed)\n".write(to: file, atomically: true, encoding: .utf8)
        try OpenSSH.run(OpenSSH.keygen, ["-q", "-H", "-f", file.path])
        let hashed = try String(contentsOf: file, encoding: .utf8)
        #expect(hashed.hasPrefix("|1|"))
        #expect(!hashed.contains("prod.example.com"))

        let list = OpenSSHKnownHosts.load([file])
        #expect(list.verdict(for: ed, host: "prod.example.com") == .trusted)
        #expect(list.verdict(for: ed, host: "[nas.local]:2222") == .trusted)
        #expect(list.verdict(for: ed, host: "staging.example.com") == .unknown)
    }

    @Test func sshsListIsTrustedFirstAndContradictionsAreRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bt-kh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "known_hosts")
        try "prod.example.com \(ed)\n@revoked bad.example.com \(otherEd)\n".write(to: file, atomically: true, encoding: .utf8)
        let store = KnownHosts(fileURL: nil, openSSHFiles: [file])
        let prod = SFTPEndpoint(host: "prod.example.com", username: "me")

        #expect(store.check(ed, for: prod))
        #expect(store.trustedKey(for: prod) == ed)

        let fresh = KnownHosts(fileURL: nil, openSSHFiles: [file])
        #expect(!fresh.check(otherEd, for: prod))
        #expect(fresh.takeRejection(for: prod) == .hostKeyChangedInKnownHosts(
            host: "prod.example.com",
            expected: KnownHosts.fingerprint(ofOpenSSHKey: ed),
            presented: KnownHosts.fingerprint(ofOpenSSHKey: otherEd)
        ))

        let bad = SFTPEndpoint(host: "bad.example.com", username: "me")
        #expect(!fresh.check(otherEd, for: bad))
        #expect(fresh.takeRejection(for: bad) == .hostKeyRevoked(host: "bad.example.com"))

        // Hosts ssh has never seen are trusted the first time, as before.
        let new = SFTPEndpoint(host: "new.example.com", username: "me")
        #expect(fresh.check(otherEd, for: new))
        #expect(!fresh.check(ed, for: new))
    }

    @Test func aKindKnownHostsDoesNotListWaitsForTheUser() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bt-kh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "known_hosts")
        try "prod.example.com \(ed)\n".write(to: file, atomically: true, encoding: .utf8)
        let store = KnownHosts(fileURL: nil, openSSHFiles: [file])
        let prod = SFTPEndpoint(host: "prod.example.com", username: "me")

        // ssh knows prod by its Ed25519 key; an ECDSA key it cannot vouch for.
        #expect(!store.check(ecdsa, for: prod))
        #expect(store.takeRejection(for: prod) == .hostKeyNotListed(host: "prod.example.com", known: [KnownHosts.fingerprint(ofOpenSSHKey: ed)], presented: ecdsa))

        // Once the user has checked it and trusts it, it is let in.
        store.trust(ecdsa, hostKeyID: "prod.example.com")
        #expect(store.check(ecdsa, for: prod))
        // The listed key still works too.
        #expect(store.check(ed, for: prod))
    }
}
