import BottariCore
import Foundation
import Testing
@testable import BottariSFTP

@Suite struct ConnectionPlanTests {
    let config = SSHConfig(
        text: """
        Host bastion
          HostName bastion.example.com
          User me
          IdentityFile ~/.ssh/id_ed25519
        """,
        directory: "/Users/me/.ssh",
        home: "/Users/me",
        localUser: "me"
    )

    func readFile(_ path: String) -> String? {
        ["/Users/me/.ssh/id_ed25519": "BASTION KEY", "/keys/prod": "PROD KEY"][path]
    }

    func site(_ name: String, _ auth: SavedSite.Authentication, via jumps: [String] = []) -> SavedSite {
        SavedSite(name: name, endpoint: SFTPEndpoint(host: "\(name).example.com", username: "deploy"), authentication: auth, proxyJump: jumps)
    }

    @Test func passwordComesFromSecretsUnlessTyped() throws {
        let nas = site("nas", .password)
        let secrets = InMemorySecretStore([nas.passwordKey: "stored"])

        #expect(try nas.credential(secrets: secrets) == .password("stored"))
        #expect(try nas.credential(secrets: secrets, password: "typed") == .password("typed"))
        #expect(throws: SiteConnectError.passwordMissing(site: "nas")) {
            try nas.credential(secrets: InMemorySecretStore())
        }
    }

    @Test func keyFilesAreReadWithTheirStoredPassphrase() throws {
        let prod = site("prod", .keyFile(path: "/keys/prod"))
        let secrets = InMemorySecretStore([prod.passphraseKey: "pp"])

        #expect(try prod.credential(secrets: secrets, readFile: readFile) == .privateKey("PROD KEY", passphrase: "pp"))
        #expect(throws: SiteConnectError.keyFileUnreadable(path: "/keys/missing")) {
            try site("x", .keyFile(path: "/keys/missing")).credential(secrets: secrets, readFile: readFile)
        }
    }

    @Test func jumpHostsResolveThroughSitesConfigAndRawAddresses() throws {
        let relay = site("relay", .agent(socket: nil), via: ["bastion"])
        let target = site("prod", .keyFile(path: "/keys/prod"), via: ["relay", "admin@edge.example.com:2200"])

        let plan = try target.connectionPlan(
            sites: [relay, target],
            sshConfig: config,
            secrets: InMemorySecretStore(),
            defaultUser: "me",
            readFile: readFile
        )

        #expect(plan.endpoint == target.endpoint)
        #expect(plan.credential == .privateKey("PROD KEY", passphrase: nil))
        #expect(plan.hops == [
            SSHHop(endpoint: SFTPEndpoint(host: "bastion.example.com", username: "me"), credential: .privateKey("BASTION KEY", passphrase: nil)),
            SSHHop(endpoint: relay.endpoint, credential: .agent(socket: nil)),
            SSHHop(endpoint: SFTPEndpoint(host: "edge.example.com", port: 2200, username: "admin"), credential: .agent(socket: nil)),
        ])
    }

    @Test func jumpLoopsAreRefused() {
        let a = site("a", .agent(socket: nil), via: ["b"])
        let b = site("b", .agent(socket: nil), via: ["a"])
        #expect(throws: SiteConnectError.jumpLoop("a")) {
            try a.connectionPlan(sites: [a, b], sshConfig: config, secrets: InMemorySecretStore(), readFile: readFile)
        }
    }

    @Test(arguments: [
        ("host", SFTPEndpoint(host: "host", username: "me")),
        ("ops@host", SFTPEndpoint(host: "host", username: "ops")),
        ("ops@host:2222", SFTPEndpoint(host: "host", port: 2222, username: "ops")),
        ("host:2222", SFTPEndpoint(host: "host", port: 2222, username: "me")),
    ])
    func hopAddressesParse(text: String, expected: SFTPEndpoint) {
        #expect(SavedSite.endpoint(parsingHop: text, defaultUser: "me") == expected)
    }
}

@Suite(.timeLimit(.minutes(1))) struct JumpHostTests {
    /// A jump host that forwards connections, and a target behind it.
    func withJumpAndTarget(_ body: (TestSFTPServer, TestSFTPServer) async throws -> Void) async throws {
        let jump = try await TestSFTPServer.start(forwarding: true)
        let target: TestSFTPServer
        do {
            target = try await TestSFTPServer.start()
        } catch {
            await jump.stop()
            throw error
        }
        do {
            try await body(jump, target)
        } catch {
            await target.stop()
            await jump.stop()
            throw error
        }
        await target.stop()
        await jump.stop()
    }

    @Test func connectsToTheTargetThroughAJumpHost() async throws {
        try await withJumpAndTarget { jump, target in
            try target.makeFile("/behind-the-bastion.txt", "hi")
            let knownHosts = KnownHosts(fileURL: nil)

            let provider = try await SFTPFileProvider.connect(
                to: target.endpoint,
                credential: .password(TestSFTPServer.password),
                hostKeys: .knownHosts(knownHosts),
                via: [SSHHop(endpoint: jump.endpoint, credential: .privateKey(jump.clientKey.makeSSHRepresentation()))]
            )

            #expect(try await provider.list(.root).map(\.name) == ["behind-the-bastion.txt"])
            #expect(try await provider.readData("/behind-the-bastion.txt") == Data("hi".utf8))
            // Each hop's host key is remembered separately.
            #expect(knownHosts.trustedKey(for: jump.endpoint) != nil)
            #expect(knownHosts.trustedKey(for: target.endpoint) != nil)
            #expect(knownHosts.trustedKey(for: jump.endpoint) != knownHosts.trustedKey(for: target.endpoint))
            await provider.disconnect()
        }
    }

    @Test func aRejectedJumpHostIsNamedInTheError() async throws {
        try await withJumpAndTarget { jump, target in
            await #expect {
                _ = try await SFTPFileProvider.connect(
                    to: target.endpoint,
                    credential: .password(TestSFTPServer.password),
                    hostKeys: .acceptAnything,
                    via: [SSHHop(endpoint: jump.endpoint, credential: .password("wrong"))]
                )
            } throws: { error in
                guard case SFTPConnectError.jumpHostFailed(let host, _) = error else { return false }
                return host == jump.endpoint.hostKeyID
            }
        }
    }

    @Test func theTargetsOwnLoginFailureIsNotBlamedOnTheJumpHost() async throws {
        try await withJumpAndTarget { jump, target in
            await #expect(throws: SFTPConnectError.authenticationFailed) {
                _ = try await SFTPFileProvider.connect(
                    to: target.endpoint,
                    credential: .password("wrong"),
                    hostKeys: .acceptAnything,
                    via: [SSHHop(endpoint: jump.endpoint, credential: .password(TestSFTPServer.password))]
                )
            }
        }
    }
}
