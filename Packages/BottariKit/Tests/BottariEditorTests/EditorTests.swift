import BottariCore
import Foundation
import Testing
@testable import BottariEditor

@Suite struct TextCodecTests {
    @Test func utf8WithCRLFRoundTrips() throws {
        let data = Data("server {\r\n  listen 80;\r\n}\r\n".utf8)
        let (text, format) = try #require(TextCodec.decode(data))
        #expect(text == "server {\n  listen 80;\n}\n")
        #expect(format == TextFormat(encoding: .utf8, lineEnding: .crlf))
        #expect(format.label == "UTF-8 CRLF")
        #expect(TextCodec.encode(text, as: format) == data)
    }

    @Test func pastedLineEndingsAreSavedAsTheFilesOwn() {
        let pasted = "a\r\nb\rc\n"
        func saved(_ lineEnding: TextFormat.LineEnding) -> [UInt8]? {
            TextCodec.encode(pasted, as: TextFormat(lineEnding: lineEnding)).map(Array.init)
        }
        #expect(saved(.lf) == Array("a\nb\nc\n".utf8))
        #expect(saved(.crlf) == Array("a\r\nb\r\nc\r\n".utf8))
        #expect(saved(.cr) == Array("a\rb\rc\r".utf8))
    }

    @Test func byteOrderMarksAreKept() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("한글\n".utf8)
        let (text, format) = try #require(TextCodec.decode(data))
        #expect(text == "한글\n")
        #expect(format.encoding == .utf8WithBOM)
        #expect(TextCodec.encode(text, as: format) == data)

        let utf16 = Data([0xFF, 0xFE]) + "a\n".data(using: .utf16LittleEndian)!
        #expect(TextCodec.decode(utf16)?.format.encoding == .utf16LittleEndian)
    }

    @Test func eucKRIsTheFallbackForKoreanBytes() throws {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        let data = try #require("안녕하세요\n".data(using: encoding))
        let (text, format) = try #require(TextCodec.decode(data))
        #expect(text == "안녕하세요\n")
        #expect(format.encoding == .eucKR)
        #expect(TextCodec.encode(text, as: format) == data)
        // Characters EUC-KR cannot hold are refused rather than lost.
        #expect(TextCodec.encode("🙂", as: format) == nil)
    }

    @Test func binaryIsNotText() {
        #expect(TextCodec.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])) == nil)
    }
}

@Suite struct ThreeWayMergeTests {
    let base = "a\nb\nc\nd\ne\n"

    @Test func changesToDifferentLinesAreBothKept() {
        let mine = "A\nb\nc\nd\ne\n"
        let theirs = "a\nb\nc\nd\nE\nf\n"
        #expect(ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) == .merged("A\nb\nc\nd\nE\nf\n"))
    }

    @Test func theSameChangeOnBothSidesIsFine() {
        let both = "a\nB\nc\nd\ne\n"
        #expect(ThreeWayMerge.merge(base: base, mine: both, theirs: both) == .merged(both))
    }

    @Test func competingChangesConflict() {
        #expect(ThreeWayMerge.merge(base: base, mine: "a\nX\nc\nd\ne\n", theirs: "a\nY\nc\nd\ne\n") == .conflict)
        // Neighbouring lines too: there is no telling which order is right.
        #expect(ThreeWayMerge.merge(base: base, mine: "a\nX\nc\nd\ne\n", theirs: "a\nb\nY\nd\ne\n") == .conflict)
    }

    @Test func insertionsAndDeletionsMerge() {
        let mine = "a\nb\nnew\nc\nd\ne\n"
        let theirs = "a\nb\nc\ne\n"
        #expect(ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) == .merged("a\nb\nnew\nc\ne\n"))
    }

    @Test func diffShowsChangesWithContext() {
        let lines = LineDiff.lines(from: "1\n2\n3\n4\n5\n6\n7\n8\n", to: "1\n2\n3\n4\nfive\n6\n7\n8\n", context: 1)
        #expect(lines == [
            .init(kind: .same, text: "4"),
            .init(kind: .removed, text: "5"),
            .init(kind: .added, text: "five"),
            .init(kind: .same, text: "6"),
        ])
    }

    @Test func languagesComeFromFileNames() {
        #expect(SyntaxHighlighting.language(forFileNamed: "nginx.conf") == "nginx")
        #expect(SyntaxHighlighting.language(forFileNamed: "docker-compose.yml") == "yaml")
        #expect(SyntaxHighlighting.language(forFileNamed: "Dockerfile") == "dockerfile")
        #expect(SyntaxHighlighting.language(forFileNamed: ".env.production") == "bash")
        #expect(SyntaxHighlighting.language(forFileNamed: "notes.txt") == nil)
    }
}

struct CheckFailed: Error {}

@MainActor @Suite struct EditedFileTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "BottariEditorTests-\(UUID().uuidString)")

    /// `contents` in a file of its own, opened for editing.
    func open(_ contents: String) async throws -> (file: EditedFile, url: URL, text: String) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "nginx.conf")
        try Data(contents.utf8).write(to: url)
        let provider = LocalFileProvider()
        let file = EditedFile(provider: provider, item: try await provider.stat(RemotePath(url.path)))
        return (file, url, try await file.open(sizeLimit: 1 << 20))
    }

    @Test func aServerCopyThatIsNoLongerTextIsNeitherMergedAwayNorKeptEmpty() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (file, url, text) = try await open("a\nb\n")
        // cp1252 "é ", which is text in neither UTF-8 nor CP949.
        let theirs = Data([0xE9, 0x20])
        try theirs.write(to: url)

        guard case .conflict(let conflict) = try await file.save(text, check: nil) else {
            Issue.record("the server's change went unnoticed")
            return
        }
        #expect(conflict.merged == nil)
        let kept = try #require(file.keepCopy(of: conflict, in: folder.appending(path: "Replaced")))
        let keptBytes = try Data(contentsOf: kept)
        #expect(keptBytes == theirs)
    }

    @Test func aFailedCheckAfterAMergePutsBackTheServersNewerCopy() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (file, url, _) = try await open("a\nb\nc\n")
        // A colleague adds a line while this edit changes the first one.
        let theirs = "a\nb\nc\nd\n"
        try Data(theirs.utf8).write(to: url)
        guard case .conflict(let conflict) = try await file.save("A\nb\nc\n", check: nil), let merged = conflict.merged else {
            Issue.record("no merge was offered")
            return
        }
        let failing: @Sendable () async throws -> Void = { throw CheckFailed() }

        guard case .checkFailed = try await file.save(merged, over: conflict, check: failing) else {
            Issue.record("the check did not fail the save")
            return
        }
        let afterMerge = try String(contentsOf: url, encoding: .utf8)
        #expect(afterMerge == theirs)

        // The next try fails its check too, and the colleague's copy is still what goes back.
        guard case .checkFailed = try await file.save(merged + "e\n", check: failing) else {
            Issue.record("the check did not fail the second save")
            return
        }
        let afterRetry = try String(contentsOf: url, encoding: .utf8)
        #expect(afterRetry == theirs)
    }
}
