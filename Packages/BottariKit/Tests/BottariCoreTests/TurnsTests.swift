import Testing
@testable import BottariCore

@MainActor @Suite struct TurnsTests {
    struct Refused: Error, Equatable {}

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
