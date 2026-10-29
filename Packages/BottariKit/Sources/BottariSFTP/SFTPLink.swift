import BottariCore
import Foundation
import Synchronization

/// The connection behind a provider, opened again when it has dropped. Without
/// this a sleeping Mac, a changed network or a restarted server leaves every
/// pane, transfer and editor on that server failing until someone reconnects
/// by hand. Copies of a provider share one link.
final class SFTPLink: Sendable {
    private struct State {
        var connection: SFTPConnection
        var reopening: Task<SFTPConnection, any Error>?
        var closed = false
        var listeners: [@Sendable () -> Void] = []
    }

    private let state: Mutex<State>
    private let reopen: @Sendable () async throws -> SFTPConnection

    init(_ connection: SFTPConnection, reopen: @escaping @Sendable () async throws -> SFTPConnection) {
        state = Mutex(State(connection: connection))
        self.reopen = reopen
        watch(connection)
    }

    /// The connection as it is now, open or not.
    var current: SFTPConnection {
        state.withLock { $0.connection }
    }

    /// An open connection. A dropped one is replaced first, and one that has
    /// been quiet for a while has to answer before it is trusted, so the first
    /// request after a nap reconnects instead of hanging.
    func live() async throws -> SFTPConnection {
        let (connection, closed) = state.withLock { ($0.connection, $0.closed) }
        guard !closed else { throw ProviderError.io(String(localized: "연결을 닫았습니다")) }
        if connection.client.isConnected {
            if connection.heartbeat.quiet < SFTPConnection.keepAliveInterval { return connection }
            if await connection.ping(within: .seconds(8)) { return connection }
            await connection.close()
        }
        return try await replace(connection)
    }

    /// Runs `body` on the connection, and once more on a new one if the old
    /// one turns out to have dropped. Only for requests that are safe to repeat.
    func retrying<T>(_ body: (SFTPConnection) async throws -> T) async throws -> T {
        let connection = try await live()
        do {
            return try await body(connection)
        } catch {
            guard !connection.client.isConnected, !state.withLock({ $0.closed }) else { throw error }
            return try await body(try await replace(connection))
        }
    }

    /// A connection of its own to the same server, e.g. to forward an agent
    /// without other work seeing it. The caller closes it.
    func openAnother() async throws -> SFTPConnection {
        try await reopen()
    }

    /// Runs `action` whenever the connection drops or is closed.
    func whenDisconnected(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.listeners.append(action) }
    }

    func close() async {
        let (connection, reopening) = state.withLock { state in
            state.closed = true
            return (state.connection, state.reopening)
        }
        reopening?.cancel()
        await connection.close()
    }

    /// A new connection in place of `stale`. Callers that find the same stale
    /// connection share one attempt.
    private func replace(_ stale: SFTPConnection) async throws -> SFTPConnection {
        let attempt: Task<SFTPConnection, any Error> = state.withLock { state in
            if let reopening = state.reopening { return reopening }
            if state.connection !== stale, state.connection.client.isConnected {
                return Task { [connection = state.connection] in connection }
            }
            let task = Task { try await self.reopened() }
            state.reopening = task
            return task
        }
        return try await attempt.value
    }

    private func reopened() async throws -> SFTPConnection {
        Log.connection.info("끊긴 연결을 다시 여는 중")
        let fresh: SFTPConnection
        do {
            fresh = try await reopen()
        } catch {
            state.withLock { $0.reopening = nil }
            Log.connection.error("다시 연결하지 못함: \(error.localizedDescription)")
            throw error
        }
        let (old, closed) = state.withLock { state in
            state.reopening = nil
            let old = state.connection
            if !state.closed { state.connection = fresh }
            return (old, state.closed)
        }
        guard !closed else {
            await fresh.close()
            throw ProviderError.io(String(localized: "연결을 닫았습니다"))
        }
        watch(fresh)
        await old.close()
        return fresh
    }

    private func watch(_ connection: SFTPConnection) {
        connection.client.onDisconnect { [weak self] in
            guard let self else { return }
            for listener in self.state.withLock({ $0.listeners }) {
                listener()
            }
        }
    }
}
