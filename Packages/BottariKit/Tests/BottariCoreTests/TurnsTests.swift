import Testing
@testable import BottariCore

/// A pane told to show one place after another, faster than they open.
@MainActor @Suite struct TurnsTests {
    struct Refused: Error, Equatable {}

    /// The user picked a server that is down, then another place before it
    /// answered: the first one's failure is not reported over the second.
    @Test func anOvertakenStepThatFailsEndsAsCancelled() async {
        let turns = Turns()
        let first = turns.take()
        await #expect(throws: CancellationError.self) {
            try await turns.run(first) {
                _ = turns.take()
                throw Refused()
            }
        }
    }

    /// One that opens after it was overtaken is let go, not shown.
    @Test func anOvertakenStepThatOpensIsDiscarded() async {
        let turns = Turns()
        var discarded: [String] = []
        let first = turns.take()
        await #expect(throws: CancellationError.self) {
            try await turns.run(first, discarding: { discarded.append($0) }) {
                _ = turns.take()
                return "old server"
            }
        }
        #expect(discarded == ["old server"])
    }

    @Test func theNewestStepLandsOrFailsAsItself() async throws {
        let turns = Turns()
        _ = turns.take()
        #expect(try await turns.run(turns.take()) { "new server" } == "new server")
        await #expect(throws: Refused()) {
            try await turns.run(turns.take()) { throw Refused() }
        }
    }
}
