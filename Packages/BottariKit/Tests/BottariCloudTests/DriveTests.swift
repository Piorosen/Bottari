import BottariCore
import Crypto
import Foundation
import Testing
@testable import BottariCloud

@Suite struct GoogleDriveProviderTests {
    let drive = "token-\(UUID().uuidString)"

    func provider(_ format: DriveExportFormat = .office) -> GoogleDriveProvider {
        GoogleDriveProvider(account: "me@example.com", tokens: FakeDrive.Token(value: drive), exportFormat: format, session: FakeDrive.session())
    }

    @Test func writesListsAndReads() async throws {
        let drive = provider()
        try await drive.makeDirectory("/사진")
        try await drive.write("/사진/고양이.jpg", data: Data("meow".utf8))
        try await drive.write("/notes.md", data: Data("# hi".utf8))
        for index in 0..<5 {
            try await drive.write(RemotePath("/사진/\(index).jpg"), data: Data([UInt8(index)]))
        }

        #expect(try await drive.list(.root).map(\.name) == ["사진", "notes.md"])
        #expect(try await drive.list("/사진").map(\.name) == ["0.jpg", "1.jpg", "2.jpg", "3.jpg", "4.jpg", "고양이.jpg"])
        #expect(try await drive.readData("/사진/고양이.jpg") == Data("meow".utf8))
        #expect(try await drive.readData("/notes.md", range: 2..<4) == Data("hi".utf8))
        #expect(try await drive.stat("/사진").isDirectory)
        #expect(try await drive.checksum("/notes.md") == SHA256.hash(data: Data("# hi".utf8)).map { String(format: "%02x", $0) }.joined())
        await #expect(throws: ProviderError.notFound("/없음")) { try await drive.stat("/없음") }
    }

    @Test func repeatedNamesStayApart() async throws {
        FakeDrive.add(drive, name: "report.pdf", data: Data("first".utf8))
        FakeDrive.add(drive, name: "report.pdf", data: Data("second".utf8))
        FakeDrive.add(drive, name: "photos", mimeType: GoogleDriveProvider.folderType)
        FakeDrive.add(drive, name: "photos", mimeType: GoogleDriveProvider.folderType)

        let drive = provider()
        #expect(try await drive.list(.root).map(\.name) == ["photos", "photos (2)", "report (2).pdf", "report.pdf"])
        #expect(try await drive.readData("/report (2).pdf") == Data("second".utf8))
    }

    @Test(arguments: [(DriveExportFormat.office, "계획.docx"), (.pdf, "계획.pdf"), (.openDocument, "계획.odt")])
    func googleDocsComeConverted(format: DriveExportFormat, name: String) async throws {
        FakeDrive.add(drive, name: "계획", mimeType: "application/vnd.google-apps.document")
        let drive = provider(format)

        #expect(try await drive.list(.root).map(\.name) == [name])
        let text = String(decoding: try await drive.readData(RemotePath("/" + name)), as: UTF8.self)
        #expect(text == "exported 계획 as \(format.export(for: "application/vnd.google-apps.document")!.mime)")
    }

    @Test func bigFilesGoUpInChunksAndUpdatesKeepTheFile() async throws {
        let drive = provider()
        let payload = Data((0..<(GoogleDriveProvider.chunkSize * 2 + 4321)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try await drive.write("/backup.tar", from: AsyncThrowingStream { continuation in
            var offset = 0
            while offset < payload.count {
                let end = min(offset + 1_000_000, payload.count)
                continuation.yield(payload.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        })
        #expect(FakeDrive.drive(self.drive).log.filter { $0.hasPrefix("PUT") }.count == 3)
        #expect(try await drive.readData("/backup.tar") == payload)

        try await drive.write("/backup.tar", data: Data("smaller".utf8))
        #expect(FakeDrive.drive(self.drive).files.count == 1)
        #expect(try await drive.readData("/backup.tar") == Data("smaller".utf8))
    }

    @Test func movesCopiesTrashesAndDeletes() async throws {
        let drive = provider()
        try await drive.makeDirectory("/a")
        try await drive.makeDirectory("/b")
        try await drive.write("/a/x.txt", data: Data("x".utf8))

        try await drive.move("/a/x.txt", to: "/b/renamed.txt")
        #expect(try await drive.list("/b").map(\.name) == ["renamed.txt"])

        try await drive.copy("/b/renamed.txt", to: "/a/copy.txt")
        #expect(try await drive.readData("/a/copy.txt") == Data("x".utf8))
        #expect(FakeDrive.drive(self.drive).log.contains { $0.hasSuffix("/copy") }, "copied by Drive itself")

        try await drive.copy("/a", to: "/a2")
        #expect(try await drive.list("/a2").map(\.name) == ["copy.txt"])

        try await drive.trash("/a2/copy.txt")
        #expect(try await drive.list("/a2").isEmpty)
        try await drive.delete("/b")
        #expect(try await drive.list(.root).map(\.name) == ["a", "a2"])
    }

    @Test func anExpiredTokenIsRefused() async throws {
        let expired = GoogleDriveProvider(account: "me", tokens: FakeDrive.Token(value: "expired"), session: FakeDrive.session())
        await #expect(throws: ProviderError.permissionDenied(.root)) { try await expired.list(.root) }
    }
}
