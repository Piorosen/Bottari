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
