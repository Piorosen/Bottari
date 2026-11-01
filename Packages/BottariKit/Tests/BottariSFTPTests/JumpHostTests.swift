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
        #expect(try site("box", .defaultKeys).credential(secrets: RefusingSecrets()) == .defaultKeys([]))
    }

    @Test func keySitesWithAPasswordTryTheKeysFirst() throws {
        let nas = site("nas", .defaultKeys)
        let prod = site("prod", .keyFile(path: "/keys/prod"))

        #expect(try nas.credential(secrets: InMemorySecretStore()) == .defaultKeys([]))
        #expect(try nas.credential(secrets: InMemorySecretStore([nas.passwordKey: "stored"]))
            == .fallback(.defaultKeys([]), then: .password("stored")))
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
        let relay = site("relay", .defaultKeys, via: ["bastion"])
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
        // Hops without a key of their own try the default key file, as `ssh` would.
        #expect(plan.hops == [
            SSHHop(endpoint: SFTPEndpoint(host: "bastion.example.com", username: "me"), credential: .privateKey("BASTION KEY", passphrase: nil)),
            SSHHop(endpoint: relay.endpoint, credential: .defaultKeys(["BASTION KEY"])),
            SSHHop(endpoint: SFTPEndpoint(host: "edge.example.com", port: 2200, username: "admin"), credential: .defaultKeys(["BASTION KEY"])),
        ])
    }

    @Test func aTunnelsServerGoesInFrontAsTheFirstHop() throws {
        let target = site("prod", .keyFile(path: "/keys/prod"), via: ["bastion"])
        let gateway = site("gateway", .keyFile(path: "/keys/prod"))
        let plan = try target.connectionPlan(sites: [gateway, target], sshConfig: config, secrets: InMemorySecretStore(), defaultUser: "me", readFile: readFile)
        let detoured = plan.through(try gateway.connectionPlan(sites: [gateway], sshConfig: config, secrets: InMemorySecretStore(), readFile: readFile))
        #expect(detoured.hops.map(\.endpoint) == [gateway.endpoint, SFTPEndpoint(host: "bastion.example.com", username: "me")])
    }

    @Test func defaultKeysAreTheKeyFilesSshTries() throws {
        let nas = site("nas", .defaultKeys)
        let files = ["/Users/me/.ssh/id_rsa": "RSA KEY", "/Users/me/.ssh/id_ed25519": "ED25519 KEY"]

        #expect(try nas.credential(secrets: InMemorySecretStore(), sshDirectory: "/Users/me/.ssh", readFile: { files[$0] })
            == .defaultKeys(["ED25519 KEY", "RSA KEY"]))
        #expect(try nas.credential(secrets: InMemorySecretStore(), sshDirectory: "/Users/me/.ssh", readFile: { _ in nil }) == .defaultKeys([]))
        #expect(try nas.credential(secrets: InMemorySecretStore(), readFile: { files[$0] }) == .defaultKeys([]))
        // With nothing to offer, the connection says where the keys should be.
        #expect(throws: SFTPConnectError.noDefaultKeys) { try SFTPCredential.defaultKeys([]).authenticationAttempts(username: "me") }
    }

    @Test func jumpLoopsAreRefused() {
        let a = site("a", .defaultKeys, via: ["b"])
        let b = site("b", .defaultKeys, via: ["a"])
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

/// A machine reached through a jump host the way a VM or a laptop often is:
/// it keeps a reverse tunnel (`ssh -R`) open to the jump host, and Bottari
/// goes to that tunnel's port there. The machine can be off, or asleep with
/// the jump host still listening for it.
@Suite(.enabled(if: OpenSSH.isAvailable), .timeLimit(.minutes(1))) struct ReverseTunnelTests {
    /// `ssh -N -R port:127.0.0.1:target jump`, as the machine runs it.
    func reverseTunnel(key: URL, jump: OpenSSHServer, port: Int, target: OpenSSHServer) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-F", "/dev/null", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
            "-o", "LogLevel=ERROR", "-i", key.path, "-p", String(jump.port),
            "-R", "\(port):127.0.0.1:\(target.port)", "\(NSUserName())@127.0.0.1",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SSH_AUTH_SOCK")
        process.environment = environment
        try process.run()
        return process
    }

    func isListening(_ port: Int) async -> Bool {
        for _ in 0..<100 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            close(fd)
            if connected == 0 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// `body`'s outcome, or nil if it has not finished within `limit`. A
    /// hung `body` is left behind rather than waited on, so the test fails
    /// instead of hanging the run.
    func within<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async -> Result<T, any Error>? {
        let (outcomes, continuation) = AsyncStream.makeStream(of: Result<T, any Error>?.self)
        Task {
            do { continuation.yield(.success(try await body())) } catch { continuation.yield(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: limit)
            continuation.yield(nil)
        }
        for await outcome in outcomes { return outcome }
        return nil
    }

    @Test func aMachineThatIsOffIsNamedWithTheJumpHost() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let jump = try await OpenSSHServer.start(authorizing: [key.publicKey])
        defer { jump.stop() }
        // Nothing listens: the machine has not opened its tunnel.
        let port = Int.random(in: 20000..<29000)
        await #expect(throws: SFTPConnectError.unreachableBehindJumpHost(address: "127.0.0.1:\(port)", jumpHost: jump.endpoint.hostKeyID, detail: String(localized: "연결 거부"))) {
            _ = try await SFTPFileProvider.connect(
                to: SFTPEndpoint(host: "127.0.0.1", port: port, username: NSUserName()),
                credential: .privateKey(key.privateKey),
                hostKeys: .acceptAnything,
                via: [SSHHop(endpoint: jump.endpoint, credential: .privateKey(key.privateKey))]
            )
        }
    }

    @Test func aMachineThatFallsAsleepLetsGoInsteadOfHanging() async throws {
        let folder = try OpenSSH.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try OpenSSH.makeKey(in: folder, type: "ed25519")
        let jump = try await OpenSSHServer.start(authorizing: [key.publicKey])
        defer { jump.stop() }
        let machine = try await OpenSSHServer.start(authorizing: [key.publicKey])
        defer { machine.stop() }
        let port = Int.random(in: 20000..<29000)
        let tunnel = try reverseTunnel(key: key.path, jump: jump, port: port, target: machine)
        defer {
            kill(tunnel.processIdentifier, SIGCONT)
            tunnel.terminate()
        }
        #expect(await isListening(port))
        let behindTunnel = SFTPEndpoint(host: "127.0.0.1", port: port, username: NSUserName())
        let credential = SFTPCredential.privateKey(key.privateKey)
        let hop = SSHHop(endpoint: jump.endpoint, credential: credential)
        let provider = try await SFTPFileProvider.connect(to: behindTunnel, credential: credential, hostKeys: .acceptAnything, via: [hop])
        _ = try await provider.list(.root)

        // The machine sleeps; the jump host still takes connections for it.
        kill(tunnel.processIdentifier, SIGSTOP)
        let pending = Task { try await provider.list(.root) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await within(.seconds(5)) { await provider.disconnect() } != nil, "closing waited on the sleeping machine")
        let listed = await within(.seconds(5)) { try await pending.value }
        #expect(listed != nil, "a request to the sleeping machine never ended")
        #expect((try? listed?.get()) == nil)

        // Connecting to it again gives up once the login times out.
        let again = await within(.seconds(30)) {
            try await SFTPFileProvider.connect(to: behindTunnel, credential: credential, hostKeys: .acceptAnything, via: [hop])
        }
        guard case .failure(SFTPConnectError.unreachableBehindJumpHost(let address, let jumpHost, _))? = again else {
            Issue.record("expected the jump host to be named, got \(String(describing: again))")
            return
        }
        #expect(address == "127.0.0.1:\(port)")
        #expect(jumpHost == jump.endpoint.hostKeyID)
    }
}
