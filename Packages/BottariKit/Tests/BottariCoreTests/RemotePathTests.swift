import Foundation
import Testing
@testable import BottariCore

@Suite struct RemotePathTests {
    @Test func normalizesSlashesDotsAndParents() {
        #expect(RemotePath("/var//www/./site/../app/").string == "/var/www/app")
        #expect(RemotePath("relative/dir").string == "/relative/dir")
    }

    @Test func parentOfRootStaysAtRoot() {
        #expect(RemotePath("/../..").isRoot)
        #expect(RemotePath("/a/../../b").string == "/b")
    }

    @Test func rootHasNoParent() {
        let root = RemotePath.root
        #expect(root.string == "/")
        #expect(root.name == "/")
        #expect(root.parent == nil)
    }

    @Test func nameAndParent() {
        let path: RemotePath = "/var/www/site"
        #expect(path.name == "site")
        #expect(path.parent == "/var/www")
        #expect(path.parent?.parent?.parent == .root)
    }

    @Test func appendingRelativePaths() {
        let base: RemotePath = "/var/www"
        #expect(base.appending("site") == "/var/www/site")
        #expect(base.appending("site/assets/../logs") == "/var/www/site/logs")
        #expect(base.appending("..") == "/var")
    }

    @Test func lineageForBreadcrumbs() {
        let lineage = RemotePath("/a/b").lineage.map(\.string)
        #expect(lineage == ["/", "/a", "/a/b"])
    }

    @Test(arguments: [
        ("/a/hero.png", "png"),
        ("/a/archive.tar.gz", "gz"),
        ("/a/.bashrc", ""),
        ("/a/Makefile", ""),
    ])
    func pathExtension(path: String, expected: String) {
        #expect(RemotePath(path).pathExtension == expected)
    }

    @Test func ancestry() {
        let site: RemotePath = "/var/www/site"
        #expect(RemotePath("/var").isAncestor(of: site))
        #expect(RemotePath.root.isAncestor(of: site))
        #expect(!site.isAncestor(of: site))
        #expect(!RemotePath("/var/w").isAncestor(of: site))
    }

    @Test func codableRoundTripUsesPlainString() throws {
        let data = try JSONEncoder().encode(["path": RemotePath("/var/www")])
        #expect(String(decoding: data, as: UTF8.self) == #"{"path":"\/var\/www"}"#)
        let decoded = try JSONDecoder().decode([String: RemotePath].self, from: data)
        #expect(decoded["path"] == "/var/www")
    }
}

@Suite struct FileNamesTests {
    @Test(arguments: ["", "  ", "a/b", ".", "..", String(repeating: "가", count: 90)])
    func badNamesAreRejected(name: String) {
        #expect(FileNames.problem(with: name) != nil)
    }

    @Test func ordinaryNamesPass() {
        #expect(FileNames.problem(with: "새 폴더") == nil)
        #expect(FileNames.problem(with: ".env") == nil)
    }

    @Test func availableNamesCountUpOnlyWhenTaken() {
        #expect(FileNames.available("새 폴더", isDirectory: true, taken: []) == "새 폴더")
        #expect(FileNames.available("새 폴더", isDirectory: true, taken: ["새 폴더", "새 폴더 2"]) == "새 폴더 3")
        #expect(FileNames.available("notes.md", isDirectory: false, taken: ["notes.md"]) == "notes 2.md")
    }
}
