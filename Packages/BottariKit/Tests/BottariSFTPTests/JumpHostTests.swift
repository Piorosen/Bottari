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
        #expect(throws: SiteConnectError.passwordMissing(site: "nas", key: nas.passwordKey)) {
            try nas.credential(secrets: InMemorySecretStore())
        }
    }

    /// A Keychain that holds everything but will not hand any of it over.
    struct RefusingSecrets: SecretStore {
        func secret(for key: String) throws -> String? { throw SecretStoreError.unreadable(key: key) }
        func setSecret(_ value: String?, for key: String) throws {}
    }

    @Test func secretsTheKeychainWillNotHandOverAreAskedForAgain() throws {
        let nas = site("nas", .password)
        #expect(throws: SiteConnectError.passwordUnreadable(site: "nas", key: nas.passwordKey)) {
            try nas.credential(secrets: RefusingSecrets())
        }
        // Typed just now, it is used as is.
        #expect(try nas.credential(secrets: RefusingSecrets(), password: "typed") == .password("typed"))
        // Keys still work; the unreadable passphrase or fallback password is left out.
        #expect(try site("prod", .keyFile(path: "/keys/prod")).credential(secrets: RefusingSecrets(), readFile: readFile)
            == .privateKey("PROD KEY", passphrase: nil))
        #expect(try site("box", .agent(socket: "/tmp/agent.sock")).credential(secrets: RefusingSecrets()) == .agent(socket: "/tmp/agent.sock"))
    }

    @Test func keySitesWithAPasswordTryTheKeysFirst() throws {
        let nas = site("nas", .agent(socket: "/tmp/agent.sock"))
        let prod = site("prod", .keyFile(path: "/keys/prod"))

        #expect(try nas.credential(secrets: InMemorySecretStore()) == .agent(socket: "/tmp/agent.sock"))
        #expect(try nas.credential(secrets: InMemorySecretStore([nas.passwordKey: "stored"]))
            == .fallback(.agent(socket: "/tmp/agent.sock"), then: .password("stored")))
        #expect(try prod.credential(secrets: InMemorySecretStore(), password: "typed", readFile: readFile)
            == .fallback(.privateKey("PROD KEY", passphrase: nil), then: .password("typed")))
    }

    @Test func aMissingJumpHostPasswordNamesThatHost() throws {
        let bastion = site("bastion", .password)
        let target = site("prod", .keyFile(path: "/keys/prod"), via: ["bastion"])

        #expect(throws: SiteConnectError.passwordMissing(site: "bastion", key: bastion.passwordKey)) {
            try target.connectionPlan(sites: [bastion, target], sshConfig: config, secrets: InMemorySecretStore(), readFile: readFile)
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
        // Agent hops also carry the default key file, as `ssh` would try it.
        #expect(plan.hops == [
            SSHHop(endpoint: SFTPEndpoint(host: "bastion.example.com", username: "me"), credential: .privateKey("BASTION KEY", passphrase: nil)),
            SSHHop(endpoint: relay.endpoint, credential: .agent(socket: nil, fallbackKeys: ["BASTION KEY"])),
            SSHHop(endpoint: SFTPEndpoint(host: "edge.example.com", port: 2200, username: "admin"), credential: .agent(socket: nil, fallbackKeys: ["BASTION KEY"])),
        ])
    }

    @Test func proxyCommandsApplyOnlyToTheServerDialledFirst() throws {
        var tunnelled = site("prod", .keyFile(path: "/keys/prod"))
        tunnelled.proxyCommand = "cloudflared access ssh --hostname %h --port %p --user %r # %n %%"
        let direct = try tunnelled.connectionPlan(sites: [tunnelled], sshConfig: config, secrets: InMemorySecretStore(), defaultUser: "me", readFile: readFile)
        #expect(direct.hops.isEmpty)
        #expect(direct.proxyCommand == "cloudflared access ssh --hostname prod.example.com --port 22 --user deploy # prod %")

        // Behind a jump host whose own ProxyCommand reaches it, the target's no longer applies.
        var gateway = site("gateway", .keyFile(path: "/keys/prod"))
        gateway.proxyCommand = "nc -X 5 -x proxy:1080 %h %p"
        var behind = tunnelled
        behind.proxyJump = ["gateway", "bastion"]
        let plan = try behind.connectionPlan(sites: [gateway, behind], sshConfig: config, secrets: InMemorySecretStore(), defaultUser: "me", readFile: readFile)
        #expect(plan.proxyCommand == nil)
        #expect(plan.hops.map(\.proxyCommand) == ["nc -X 5 -x proxy:1080 gateway.example.com 22", nil])

        // A tunnel's server put in front becomes the first hop, with its ProxyCommand.
        let detoured = direct.through(try gateway.connectionPlan(sites: [gateway], sshConfig: config, secrets: InMemorySecretStore(), readFile: readFile))
        #expect(detoured.proxyCommand == nil)
        #expect(detoured.hops.map(\.proxyCommand) == ["nc -X 5 -x proxy:1080 gateway.example.com 22"])
    }

    @Test func agentFallsBackToTheDefaultKeyFiles() throws {
        let nas = site("nas", .agent(socket: "/tmp/agent.sock"))
        let files = ["/Users/me/.ssh/id_rsa": "RSA KEY", "/Users/me/.ssh/id_ed25519": "ED25519 KEY"]

        #expect(try nas.credential(secrets: InMemorySecretStore(), sshDirectory: "/Users/me/.ssh", readFile: { files[$0] })
            == .agent(socket: "/tmp/agent.sock", fallbackKeys: ["ED25519 KEY", "RSA KEY"]))
        #expect(try nas.credential(secrets: InMemorySecretStore(), sshDirectory: "/Users/me/.ssh", readFile: { _ in nil })
            == .agent(socket: "/tmp/agent.sock"))
        #expect(try nas.credential(secrets: InMemorySecretStore(), readFile: { files[$0] }) == .agent(socket: "/tmp/agent.sock"))
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
        ("[2001:db8::1]:2222", SFTPEndpoint(host: "2001:db8::1", port: 2222, username: "me")),
        ("ops@[2001:db8::1]", SFTPEndpoint(host: "2001:db8::1", username: "ops")),
        ("ops@2001:db8::1", SFTPEndpoint(host: "2001:db8::1", username: "ops")),
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

    @Test func connectsThroughAProxyCommand() async throws {
        try await withJumpAndTarget { _, target in
            try target.makeFile("/piped.txt", "through nc")
            let provider = try await SFTPFileProvider.connect(
                to: target.endpoint,
                credential: .password(TestSFTPServer.password),
                hostKeys: .acceptAnything,
                proxyCommand: "/usr/bin/nc 127.0.0.1 \(target.port)"
            )
            #expect(try await provider.readData("/piped.txt") == Data("through nc".utf8))
            await provider.disconnect()
        }
    }

    @Test func aFailingProxyCommandSaysWhatItPrinted() async throws {
        await #expect(throws: SFTPConnectError.proxyCommandFailed(command: "echo 'no route to db' >&2; exit 1", reason: "no route to db")) {
            _ = try await SFTPFileProvider.connect(
                to: SFTPEndpoint(host: "db.internal", username: "me"),
                credential: .password("pw"),
                hostKeys: .acceptAnything,
                proxyCommand: "echo 'no route to db' >&2; exit 1"
            )
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
