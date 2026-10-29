import Foundation
import os
import Synchronization

/// What Bottari did, for working out later why something failed. Every line
/// goes to the unified log (Console.app, subsystem `io.github.piorosen.bottari`)
/// and, once the app names one, to a file the user can attach to a report.
/// Nothing secret is written: no passwords, passphrases or key material.
public enum Log {
    public static let connection = LogChannel("connection")
    public static let transfer = LogChannel("transfer")
    public static let app = LogChannel("app")

    /// Where lines are also written; nil (the default, and in tests) keeps
    /// them in the unified log only. The file is cut over at about a megabyte,
    /// keeping one older file beside it with `.1` before the extension.
    public static func writeToFile(at url: URL?) {
        sink.withLock { $0 = url.map(FileSink.init) }
    }

    /// The file's lines and the older file's, oldest first, at most `limit`.
    public static func recentLines(limit: Int = 5000) -> [String] {
        guard let url = sink.withLock({ $0?.url }) else { return [] }
        let text = [FileSink.olderURL(for: url), url]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined()
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit).map(String.init))
    }

    static let sink = Mutex<FileSink?>(nil)
    static let subsystem = "io.github.piorosen.bottari"
}

/// One area's lines.
public struct LogChannel: Sendable {
    private let logger: Logger
    private let category: String

    init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: Log.subsystem, category: category)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    /// Local time with its offset, so lines match the clock the user saw.
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

    private func write(_ level: String, _ message: String) {
        let line = "\(Date().formatted(Self.timestamp)) \(level) [\(category)] \(message)\n"
        Log.sink.withLock { $0?.append(line) }
    }
}

struct FileSink {
    let url: URL
    private static let limit = 1_000_000

    init(_ url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func olderURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(url.pathExtension)
    }

    func append(_ line: String) {
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.limit {
            let older = Self.olderURL(for: url)
            try? manager.removeItem(at: older)
            try? manager.moveItem(at: url, to: older)
        }
        guard let handle = (try? FileHandle(forWritingTo: url)) ?? {
            manager.createFile(atPath: url.path, contents: nil)
            return try? FileHandle(forWritingTo: url)
        }() else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
