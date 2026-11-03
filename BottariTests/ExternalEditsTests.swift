@testable import Bottari
import BottariCore
import Foundation
import Testing

struct ExternalEditsTests {
    @Test func quittingEndsTheSessionsAndDeletesTheCopies() async throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let server = StandInServer("web", folder: try scratch.folder("server"))
        try Data("API_KEY=secret".utf8).write(to: server.folder.appending(path: ".env"))
        let item = try await server.stat(server.home.appending(".env"))
        var opened: [URL] = []
        let edits = ExternalEdits(folder: scratch.url.appending(path: "editing"), openFile: { opened.append($0) })
        edits.start(item: item, provider: server, site: nil)
        for _ in 0..<200 where opened.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let copy = try #require(opened.first)
        #expect(FileManager.default.fileExists(atPath: copy.path))

        edits.endAll()

        #expect(edits.sessions.isEmpty)
        #expect(FileManager.default.fileExists(atPath: copy.path) == false)
    }

    @Test func launchingDeletesCopiesLeftBehind() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let folder = scratch.url.appending(path: "editing")
        let leftover = folder.appending(path: UUID().uuidString).appending(path: ".env")
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("API_KEY=secret".utf8).write(to: leftover)

        ExternalEdits(folder: folder, openFile: { _ in }).endAll()

        #expect(FileManager.default.fileExists(atPath: leftover.path) == false)
    }
}
