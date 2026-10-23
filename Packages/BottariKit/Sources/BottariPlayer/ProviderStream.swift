import BottariCore
import Foundation

/// One file's bytes for mpv, read from its provider as mpv asks.
///
/// mpv reads on its own thread and expects blocking calls. A reader runs ahead
/// of mpv's position, keeping up to `aheadLimit` bytes; a seek inside what is
/// already buffered just moves forward, anything else starts the reader again
/// at the new position. Nothing is written to disk.
public final class ProviderStream: @unchecked Sendable {
    public let provider: any FileProvider
    public let path: RemotePath
    public let size: Int64?
    let aheadLimit: Int

    private let condition = NSCondition()
    // Guarded by `condition`.
    private var bytes: [UInt8] = []
    private var readIndex = 0
    private var position: Int64 = 0
    private var finished = false
    private var failure: (any Error)?
    private var cancelled = false
    private var generation = 0
    private var reader: Task<Void, Never>?
    private var requests: [Int64] = []

    /// Called (on the reader's thread) with each offset reading starts from, for the "recent reads" list.
    public var onRequest: (@Sendable (Int64) -> Void)?

    public init(provider: any FileProvider, path: RemotePath, size: Int64?, aheadLimit: Int = 16 << 20) {
        self.provider = provider
        self.path = path
        self.size = size
        self.aheadLimit = aheadLimit
    }

    deinit {
        reader?.cancel()
    }

    /// Offsets reading has started from, oldest first.
    public var startOffsets: [Int64] {
        condition.lock()
        defer { condition.unlock() }
        return requests
    }

    /// Blocks until bytes are there. Returns how many were copied, 0 at the
    /// end of the file, -1 on error or after `cancel()`.
    public func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        if reader == nil, !finished { startReading(at: position) }
        while buffered == 0, !finished, !cancelled {
            condition.wait()
        }
        if cancelled { return -1 }
        guard buffered > 0 else { return failure == nil ? 0 : -1 }
        let count = min(count, buffered)
        bytes.withUnsafeBytes { source in
            buffer.copyMemory(from: source.baseAddress! + readIndex, byteCount: count)
        }
        readIndex += count
        position += Int64(count)
        if readIndex > 4 << 20 {
            bytes.removeFirst(readIndex)
            readIndex = 0
        }
        condition.broadcast()
        return Int64(count)
    }

    /// Moves to `offset`, reusing buffered bytes when it lies within them.
    public func seek(to offset: Int64) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        let ahead = offset - position
        if ahead == 0, reader != nil || finished {
            return offset
        }
        if ahead > 0, ahead <= Int64(buffered) {
            readIndex += Int(ahead)
            position = offset
            condition.broadcast()
            return offset
        }
        startReading(at: offset)
        return offset
    }

    /// Wakes a blocked read and fails later ones; mpv calls this when it gives up.
    public func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    public func close() {
        condition.lock()
        generation += 1
        reader?.cancel()
        reader = nil
        condition.broadcast()
        condition.unlock()
    }

    private var buffered: Int { bytes.count - readIndex }

    /// Call with `condition` locked.
    private func startReading(at offset: Int64) {
        generation += 1
        let current = generation
        reader?.cancel()
        bytes.removeAll(keepingCapacity: true)
        readIndex = 0
        position = offset
        finished = false
        failure = nil
        requests.append(offset)
        if requests.count > 50 { requests.removeFirst() }
        if let size, offset >= size {
            finished = true
            reader = nil
            return
        }
        let range: Range<Int64>? = size.map { offset..<$0 } ?? (offset == 0 ? nil : offset..<Int64.max)
        let stream = provider.read(path, range: range)
        onRequest?(offset)
        reader = Task.detached { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self else { return }
                    // Stay at most `aheadLimit` ahead of mpv; wait without blocking a thread.
                    while self.isFull(current), !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard self.append(chunk, for: current) else { return }
                }
                self?.finish(current, failure: nil)
            } catch {
                self?.finish(current, failure: error)
            }
        }
    }

    private func isFull(_ current: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return generation == current && buffered >= aheadLimit
    }

    private func append(_ chunk: Data, for current: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard generation == current else { return false }
        bytes.append(contentsOf: chunk)
        condition.broadcast()
        return true
    }

    private func finish(_ current: Int, failure: (any Error)?) {
        condition.lock()
        defer { condition.unlock() }
        guard generation == current else { return }
        finished = true
        if !(failure is CancellationError) {
            self.failure = failure
        }
        condition.broadcast()
    }
}
