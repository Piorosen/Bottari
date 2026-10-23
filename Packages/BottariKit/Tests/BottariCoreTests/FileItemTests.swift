import Testing
@testable import BottariCore

@Suite struct FileItemTests {
    @Test func permissionStringMatchesLs() {
        let dir = FileItem(path: "/var/www", kind: .directory, permissions: 0o755)
        let secret = FileItem(path: "/app.env", kind: .file, permissions: 0o600)
        let link = FileItem(path: "/latest", kind: .directory, isSymbolicLink: true, permissions: 0o777)
        #expect(dir.permissionString == "drwxr-xr-x")
        #expect(secret.permissionString == "-rw-------")
        #expect(link.permissionString == "lrwxrwxrwx")
        #expect(FileItem(path: "/drive-doc", kind: .file).permissionString == nil)
    }

    @Test func finderOrderPutsDirectoriesFirstAndComparesNumbersNaturally() {
        let items = [
            FileItem(path: "/file10.txt", kind: .file),
            FileItem(path: "/b", kind: .directory),
            FileItem(path: "/File2.txt", kind: .file),
            FileItem(path: "/a", kind: .directory),
        ]
        let names = items.sorted(by: FileItem.finderOrder).map(\.name)
        #expect(names == ["a", "b", "File2.txt", "file10.txt"])
    }

    @Test func hiddenFilesStartWithDot() {
        #expect(FileItem(path: "/.ssh", kind: .directory).isHidden)
        #expect(!FileItem(path: "/ssh", kind: .directory).isHidden)
    }
}
