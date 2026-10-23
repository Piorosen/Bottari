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

    private init(socket: String, process: Process) {
        self.socket = socket
        self.process = process
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
        try process.run()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) {
            usleep(20_000)
        }
        guard FileManager.default.fileExists(atPath: socket) else {
            process.terminate()
            throw Failure(reason: "ssh-agent did not create its socket")
        }
        return TestAgent(socket: socket, process: process)
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
        try add.run()
        add.waitUntilExit()
        guard add.terminationStatus == 0 else { throw Failure(reason: "ssh-add exited with \(add.terminationStatus)") }
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
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
            let agentKey = try #require(AgentEd25519PrivateKey(agent: client, identity: try client.identities()[0]))
            let message = Data("session id + userauth request".utf8)

            let signature = try agentKey.signature(for: message)

            #expect(agentKey.rawPublicKey == key.publicKey.rawRepresentation)
            #expect(key.publicKey.isValidSignature(signature.rawRepresentation, for: message))
            #expect(agentKey.publicKey.isValidSignature(signature, for: message))
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

    @Test func emptyAgentHasNoUsableKeys() async throws {
        try await withAgent { agent in
            #expect(throws: SFTPConnectError.agentHasNoUsableKeys) {
                _ = try SFTPCredential.agent(socket: agent.socket).authenticationAttempts(username: "me")
            }
        }
    }

    @Test func missingSocketMeansNoAgent() {
        #expect(throws: SFTPConnectError.agentUnavailable) {
            _ = try SFTPCredential.agent(socket: "/tmp/bt-no-such-agent.sock").authenticationAttempts(username: "me")
        }
    }

    @Test func socketFallsBackToSSHAuthSock() {
        #expect(SSHAgentClient(socket: nil, environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock"])?.socketPath == "/tmp/agent.sock")
        #expect(SSHAgentClient(socket: nil, environment: [:]) == nil)
        #expect(SSHAgentClient(socket: "/explicit.sock", environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock"])?.socketPath == "/explicit.sock")
    }
}
