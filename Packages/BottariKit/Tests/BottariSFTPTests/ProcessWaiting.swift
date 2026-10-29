import Foundation

extension Process {
    /// Starts the process and returns what signals its end. `waitUntilExit()`
    /// hears of the end through the run loop of the thread that started the
    /// process, which the threads async tests run on do not keep turning, so
    /// it can wait forever; a termination handler runs on a queue of its own.
    func start() throws -> DispatchSemaphore {
        let ended = DispatchSemaphore(value: 0)
        terminationHandler = { _ in ended.signal() }
        try run()
        return ended
    }

    func runToEnd() throws {
        try start().wait()
    }

    /// Sends SIGTERM and waits up to five seconds for the process to go.
    func stop(waitingOn ended: DispatchSemaphore) {
        kill(processIdentifier, SIGTERM)
        _ = ended.wait(timeout: .now() + .seconds(5))
    }
}
