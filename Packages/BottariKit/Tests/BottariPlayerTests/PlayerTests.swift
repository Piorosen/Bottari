import AVFoundation
import BottariCore
import CoreVideo
import Foundation
import Testing
@testable import BottariPlayer

/// A two-second 320×240 H.264 movie, made with AVFoundation.
func makeMovie(at url: URL, seconds: Int = 2) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<(seconds * 10) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 12 % 255), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

@Suite(.timeLimit(.minutes(1))) struct ProviderStreamTests {
    func withFile(_ bytes: Int, _ body: (LocalFileProvider, FileItem, Data) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bottari-stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try data.write(to: url)
        let provider = LocalFileProvider()
        try await body(provider, try await provider.stat(RemotePath(url.path)), data)
    }

    /// Runs `work` on a thread of its own. mpv calls the stream from its own
    /// threads; blocking a Swift concurrency thread instead can starve the
    /// task that feeds the stream, and on a machine with few cores hang.
    func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: work()) }.start()
        }
    }

    func read(_ stream: ProviderStream, _ count: Int) async -> (result: Int, bytes: Data) {
        await onOwnThread {
            var buffer = [UInt8](repeating: 0, count: count)
            let result = buffer.withUnsafeMutableBytes { Int(stream.read(into: $0.baseAddress!, count: count)) }
            return (result, Data(buffer.prefix(max(0, result))))
        }
    }

    func readAll(_ stream: ProviderStream, chunk: Int = 1000) async -> Data {
        var out = Data()
        while true {
            let (count, bytes) = await read(stream, chunk)
            guard count > 0 else { break }
            out.append(bytes)
        }
        return out
    }

    @Test func readsInOrderAndSeeksWithinWhatIsBuffered() async throws {
        try await withFile(300_000) { provider, item, data in
            let stream = ProviderStream(provider: provider, path: item.path, size: item.size)
            #expect(stream.seek(to: 0) == 0)
            #expect(await readAll(stream) == data)
            // Back to the start: reading begins again there.
            #expect(stream.seek(to: 100) == 100)
            #expect(await read(stream, 10).bytes == data.subdata(in: 100..<110))
            try await Task.sleep(for: .milliseconds(100))
            // Forward within the buffered bytes: no new read.
            #expect(stream.seek(to: 50_000) == 50_000)
            #expect(await read(stream, 10).bytes == data.subdata(in: 50_000..<50_010))
            #expect(stream.startOffsets == [0, 100])
        }
    }

    @Test func staysABoundedDistanceAhead() async throws {
        try await withFile(2_000_000) { provider, item, data in
            let stream = ProviderStream(provider: provider, path: item.path, size: item.size, aheadLimit: 300_000)
            _ = stream.seek(to: 0)
            _ = await read(stream, 10)
            try await Task.sleep(for: .milliseconds(200))
            // Jumping past the buffered window starts a new read there.
            #expect(stream.seek(to: 1_500_000) == 1_500_000)
            #expect(await read(stream, 10).bytes == data.subdata(in: 1_500_000..<1_500_010))
            #expect(stream.startOffsets == [0, 1_500_000])
        }
    }

    @Test func cancellingWakesABlockedRead() async throws {
        let blocked = ProviderStream(provider: NeverEndingProvider(), path: "/slow", size: 10)
        _ = blocked.seek(to: 0)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            blocked.cancel()
        }
        #expect(await read(blocked, 4).result == -1)
    }
}

@Suite(.timeLimit(.minutes(1)), .serialized) struct MPVPlayerTests {
    @Test func playsAndSeeksAFileFromAProvider() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bottari-movie-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await makeMovie(at: url)
        let provider = LocalFileProvider()
        let item = try await provider.stat(RemotePath(url.path))

        let player = try MPVPlayer(layer: nil)
        defer { player.shutDown() }
        player.play(item, from: provider)
        player.setPaused(false)

        try await eventually { player.state.duration > 1.5 && player.state.position > 0.3 }
        #expect(abs(player.state.duration - 2) < 0.2)
        #expect(player.state.tracks.contains { $0.kind == .video && $0.codec == "h264" })
        #expect(player.stream?.startOffsets.first == 0)

        player.setPaused(true)
        player.seek(to: 1.5)
        try await eventually { abs(player.state.position - 1.5) < 0.15 }
    }

    func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A provider whose reads never deliver anything.
struct NeverEndingProvider: FileProvider {
    var displayName: String { "slow" }
    var locationID: String { "never://" }
    var capabilities: ProviderCapabilities { [.rangeRead] }
    var home: RemotePath { .root }
    func list(_ path: RemotePath) async throws -> [FileItem] { [] }
    func stat(_ path: RemotePath) async throws -> FileItem { FileItem(path: path, kind: .file) }
    func read(_ path: RemotePath, range: Range<Int64>?) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(unfolding: {
            try await Task.sleep(for: .seconds(3600))
            return nil
        })
    }
    func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws {}
    func makeDirectory(_ path: RemotePath) async throws {}
    func move(_ from: RemotePath, to: RemotePath) async throws {}
    func delete(_ path: RemotePath) async throws {}
}
