/// Steps that can overlap, such as the places a pane is told to show one after
/// another: each step takes a turn, and only the newest turn may land.
@MainActor
public final class Turns {
    private var newest = 0

    public init() {}

    /// A new turn; the ones taken before it are overtaken.
    public func take() -> Int {
        newest += 1
        return newest
    }

    public func isNewest(_ turn: Int) -> Bool {
        turn == newest
    }

    /// What `step`, run for `turn`, comes to: its value or its error, or
    /// `CancellationError` when a newer turn was taken while it ran, whether
    /// it succeeded or failed. A value that comes too late goes to `discard`.
    public func run<T>(_ turn: Int, discarding discard: (T) async -> Void = { _ in }, _ step: () async throws -> T) async throws -> T {
        let value: T
        do {
            value = try await step()
        } catch {
            guard isNewest(turn) else { throw CancellationError() }
            throw error
        }
        guard isNewest(turn) else {
            await discard(value)
            throw CancellationError()
        }
        return value
    }
}
