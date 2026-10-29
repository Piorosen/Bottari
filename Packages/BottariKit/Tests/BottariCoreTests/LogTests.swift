import Foundation
import Testing
@testable import BottariCore

@Suite(.serialized) struct LogTests {
    @Test func linesGoToTheFileAndRollOverAtAMegabyte() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bt-log-\(UUID().uuidString)")
        defer {
            Log.writeToFile(at: nil)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appending(path: "bottari.log")
        Log.writeToFile(at: file)
        let marker = UUID().uuidString
        Log.app.info("시작 \(marker)")
        Log.transfer.error("실패 \(marker)")
        let lines = Log.recentLines()
        #expect(lines.contains { $0.contains("INFO [app] 시작 \(marker)") })
        #expect(lines.contains { $0.contains("ERROR [transfer] 실패 \(marker)") })

        // Past the limit the file moves aside and a new one starts.
        try Data(repeating: 0x61, count: 1_100_000).write(to: file)
        Log.app.info("새 파일 \(marker)")
        let older = folder.appending(path: "bottari.1.log")
        #expect(FileManager.default.fileExists(atPath: older.path))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("새 파일 \(marker)"))
        #expect(Log.recentLines(limit: 1).first?.contains("새 파일 \(marker)") == true)
    }
}
