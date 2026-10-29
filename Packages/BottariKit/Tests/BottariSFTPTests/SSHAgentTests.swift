import Citadel
import Crypto
import Foundation
import Testing
@testable import BottariSFTP

/// A real `ssh-agent` listening on a temporary socket.
final class TestAgent {
    struct Failure: Error {
        let reason: String
    }

    let socket: String
    private let process: Process
    private let ended: DispatchSemaphore

    private init(socket: String, process: Process, ended: DispatchSemaphore) {
        self.socket = socket
        self.process = process
        self.ended = ended
    }

    static func start() throws -> TestAgent {
        // Unix socket paths are limited to about 100 bytes, so keep the name short.
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("bt-\(UUID().uuidString.prefix(8)).sock").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        process.arguments = ["-D", "-a", socket]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let ended = try process.start()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) {
            usleep(20_000)
        }
        guard FileManager.default.fileExists(atPath: socket) else {
            process.stop(waitingOn: ended)
            throw Failure(reason: "ssh-agent did not create its socket")
        }
        return TestAgent(socket: socket, process: process, ended: ended)
    }

    func add(_ key: Curve25519.Signing.PrivateKey, comment: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bt-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try key.makeSSHRepresentation(comment: comment).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        add.arguments = ["-q", file.path]
        add.environment = ["SSH_AUTH_SOCK": socket]
        add.standardOutput = FileHandle.nullDevice
        add.standardError = FileHandle.nullDevice
        try add.runToEnd()
        guard add.terminationStatus == 0 else { throw Failure(reason: "ssh-add exited with \(add.terminationStatus)") }
    }

    /// Adds a fresh key of a kind `TestAgent.add` cannot make, e.g. `ecdsa`.
    func addNewKey(ofType type: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bt-key-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(atPath: file.path + ".pub")
        }
        for (tool, arguments) in [("ssh-keygen", ["-q", "-t", type, "-N", "", "-f", file.path]), ("ssh-add", ["-q", file.path])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)")
            process.arguments = arguments
            process.environment = ["SSH_AUTH_SOCK": socket]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.runToEnd()
            guard process.terminationStatus == 0 else { throw Failure(reason: "\(tool) exited with \(process.terminationStatus)") }
        }
    }

    func stop() {
        process.stop(waitingOn: ended)
        try? FileManager.default.removeItem(atPath: socket)
    }
}

@Suite(.timeLimit(.minutes(1))) struct SSHAgentTests {
    func withAgent(_ body: (TestAgent) async throws -> Void) async throws {
        let agent = try TestAgent.start()
        do {
            try await body(agent)
        } catch {
            agent.stop()
            throw error
        }
        agent.stop()
    }

    @Test func listsIdentitiesFromARealAgent() async throws {
        try await withAgent { agent in
            try agent.add(Curve25519.Signing.PrivateKey(), comment: "work laptop")

            let client = try #require(SSHAgentClient(socket: agent.socket))
            let identities = try client.identities()

            #expect(identities.count == 1)
            #expect(identities.first?.keyType == "ssh-ed25519")
            #expect(identities.first?.comment == "work laptop")
        }
    }

    @Test func agentSignaturesVerifyWithThePublicKey() async throws {
        try await withAgent { agent in
            let key = Curve25519.Signing.PrivateKey()
            try agent.add(key, comment: "signer")
            let client = try #require(SSHAgentClient(socket: agent.socket))
            let agentKey = client.key(Ed25519Kind.self, try client.identities()[0])
            let message = Data("session id + userauth request".utf8)

            let signature = try agentKey.signature(for: message)

            #expect(agentKey.publicKey.rawRepresentation == Data([0, 0, 0, 32]) + key.publicKey.rawRepresentation)
            #expect(key.publicKey.isValidSignature(signature.rawRepresentation, for: message))
            #expect(agentKey.publicKey.isValidSignature(signature, for: message))
            #expect(!agentKey.publicKey.isValidSignature(signature, for: Data("something else".utf8)))
        }
    }

    @Test(arguments: ["rsa", "ecdsa"])
    func agentRSAAndECDSASignaturesVerify(type: String) async throws {
        try await withAgent { agent in
            try agent.addNewKey(ofType: type)
            let client = try #require(SSHAgentClient(socket: agent.socket))
            let identity = try client.identities()[0]
            let message = Data("session id + userauth request".utf8)
            if type == "rsa" {
                let sha2 = client.key(RSASHA512Kind.self, identity, flags: RSASHA512Kind.agentFlags)
                #expect(sha2.publicKey.isValidSignature(try sha2.signature(for: message), for: message))
                let sha1 = client.key(RSASHA1Kind.self, identity, flags: RSASHA1Kind.agentFlags)
                #expect(sha1.publicKey.isValidSignature(try sha1.signature(for: message), for: message))
            } else {
                let key = client.key(ECDSAP256Kind.self, identity)
                #expect(key.publicKey.isValidSignature(try key.signature(for: message), for: message))
            }
        }
    }

    @Test func connectsThroughTheAgentTryingEachKey() async throws {
        try await withAgent { agent in
            let server = try await TestSFTPServer.start()
            do {
                try agent.add(Curve25519.Signing.PrivateKey(), comment: "some other key")
                try agent.add(server.clientKey, comment: "the right key")
                try server.makeFile("/hello.txt", "hi")

                let provider = try await SFTPFileProvider.connect(
                    to: server.endpoint,
                    credential: .agent(socket: agent.socket),
                    hostKeys: .acceptAnything
                )
                #expect(try await provider.list(.root).map(\.name) == ["hello.txt"])
                await provider.disconnect()
            } catch {
                await server.stop()
                throw error
            }
            await server.stop()
        }
    }

    @Test func agentWithoutTheRightKeyIsRejected() async throws {
        try await withAgent { agent in
            let server = try await TestSFTPServer.start()
            try agent.add(Curve25519.Signing.PrivateKey(), comment: "unrelated")
            await #expect(throws: SFTPConnectError.authenticationFailed) {
                _ = try await SFTPFileProvider.connect(
                    to: server.endpoint,
                    credential: .agent(socket: agent.socket),
                    hostKeys: .acceptAnything
                )
            }
            await server.stop()
        }
    }

    @Test func emptyAgentFallsBackToAKeyFile() async throws {
        try await withAgent { agent in
            let server = try await TestSFTPServer.start()
            do {
                try server.makeFile("/hello.txt", "hi")

                let provider = try await SFTPFileProvider.connect(
                    to: server.endpoint,
                    credential: .agent(socket: agent.socket, fallbackKeys: [server.clientKey.makeSSHRepresentation(comment: "id_ed25519")]),
                    hostKeys: .acceptAnything
                )
                #expect(try await provider.list(.root).map(\.name) == ["hello.txt"])
                await provider.disconnect()
            } catch {
                await server.stop()
                throw error
            }
            await server.stop()
        }
    }

    @Test func aRefusedKeyFallsBackToThePassword() async throws {
        try await withAgent { agent in
            let server = try await TestSFTPServer.start()
            do {
                try agent.add(Curve25519.Signing.PrivateKey(), comment: "not on the server")
                try server.makeFile("/hello.txt", "hi")

                for keys in [SFTPCredential.agent(socket: agent.socket), .agent(socket: "/tmp/bt-no-such-agent.sock")] {
                    let provider = try await SFTPFileProvider.connect(
                        to: server.endpoint,
                        credential: .fallback(keys, then: .password(TestSFTPServer.password)),
                        hostKeys: .acceptAnything
                    )
                    #expect(try await provider.list(.root).map(\.name) == ["hello.txt"])
                    await provider.disconnect()
                }
            } catch {
                await server.stop()
                throw error
            }
            await server.stop()
        }
    }

    @Test func fallbackKeysComeAfterTheAgentsAndUnreadableOnesAreSkipped() async throws {
        try await withAgent { agent in
            try agent.add(Curve25519.Signing.PrivateKey(), comment: "agent key")
            let file = Curve25519.Signing.PrivateKey().makeSSHRepresentation(comment: "file key")

            let attempts = try SFTPCredential.agent(socket: agent.socket, fallbackKeys: ["not a key", file])
                .authenticationAttempts(username: "me")

            #expect(attempts.count == 2)
        }
    }

    @Test func emptyAgentWithoutKeyFilesSaysItIsEmpty() async throws {
        try await withAgent { agent in
            #expect(throws: SFTPConnectError.agentHasNoKeys) {
                _ = try SFTPCredential.agent(socket: agent.socket, fallbackKeys: ["not a key"]).authenticationAttempts(username: "me")
            }
        }
    }

    @Test func everyKindOfAgentKeyIsOfferedAndRSATwice() async throws {
        try await withAgent { agent in
            try agent.addNewKey(ofType: "ecdsa")
            try agent.addNewKey(ofType: "rsa")
            try agent.add(Curve25519.Signing.PrivateKey(), comment: "ed")
            let attempts = try SFTPCredential.agent(socket: agent.socket).authenticationAttempts(username: "me")
            #expect(attempts.count == 4)
        }
    }

    @Test func certificatesAndSecurityKeysAreNotOffered() throws {
        let client = try #require(SSHAgentClient(socket: "/tmp/bt-no-such-agent.sock"))
        func identity(_ type: String) -> SSHAgentClient.Identity {
            var blob = Data()
            blob.appendSSHString(Data(type.utf8))
            blob.appendSSHString(Data(repeating: 1, count: 32))
            return SSHAgentClient.Identity(blob: blob, comment: "")
        }
        let identities = ["sk-ssh-ed25519@openssh.com", "ssh-ed25519-cert-v01@openssh.com", "ssh-dss"].map(identity)
        #expect(client.offers(for: identities, username: "me").isEmpty)
        #expect(client.offers(for: [identity("ssh-ed25519")], username: "me").count == 1)
    }

    @Test func missingSocketMeansNoAgent() {
        #expect(throws: SFTPConnectError.agentUnavailable) {
            _ = try SFTPCredential.agent(socket: "/tmp/bt-no-such-agent.sock").authenticationAttempts(username: "me")
        }
    }

    @Test func missingAgentStillUsesKeyFiles() throws {
        let file = Curve25519.Signing.PrivateKey().makeSSHRepresentation(comment: "file key")
        let attempts = try SFTPCredential.agent(socket: "/tmp/bt-no-such-agent.sock", fallbackKeys: [file])
            .authenticationAttempts(username: "me")
        #expect(attempts.count == 1)
    }

    @Test func socketFallsBackToSSHAuthSock() {
        #expect(SSHAgentClient(socket: nil, environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock"])?.socketPath == "/tmp/agent.sock")
        #expect(SSHAgentClient(socket: nil, environment: [:]) == nil)
        #expect(SSHAgentClient(socket: "/explicit.sock", environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock"])?.socketPath == "/explicit.sock")
    }
}
