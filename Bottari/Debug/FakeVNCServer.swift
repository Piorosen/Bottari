#if DEBUG
import Foundation
import Network

/// The smallest RFB 3.8 server that gets a client to its first framebuffer:
/// no authentication, a 800×600 screen, and input read and ignored.
nonisolated final class FakeVNCServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-vnc")
    private(set) var port: UInt16 = 0
    private var started = false

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            // Called on `queue` only.
            listener.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let self, !self.started else { return }
                self.started = true
                self.port = self.listener.port?.rawValue ?? 0
                continuation.resume(returning: self.port)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.send(content: Data("RFB 003.008\n".utf8), completion: .contentProcessed { _ in })
        receive(connection, exactly: 12) { _ in
            // One security type: None.
            connection.send(content: Data([1, 1]), completion: .contentProcessed { _ in })
            self.receive(connection, exactly: 1) { _ in
                connection.send(content: Data([0, 0, 0, 0]), completion: .contentProcessed { _ in })
                self.receive(connection, exactly: 1) { _ in
                    var serverInit = Data([0x03, 0x20, 0x02, 0x58]) // 800 × 600
                    // 32 bits per pixel, depth 24, little endian, true colour, max 255 each, shifts 16/8/0.
                    serverInit += Data([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
                    let name = Data("Bottari test".utf8)
                    serverInit += Data([0, 0, 0, UInt8(name.count)]) + name
                    connection.send(content: serverInit, completion: .contentProcessed { _ in })
                    self.discard(connection)
                }
            }
        }
    }

    private func receive(_ connection: NWConnection, exactly count: Int, then: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            guard error == nil, let data else { return }
            then(data)
        }
    }

    private func discard(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, done, error in
            guard error == nil, !done else { return }
            self?.discard(connection)
        }
    }
}
#endif
