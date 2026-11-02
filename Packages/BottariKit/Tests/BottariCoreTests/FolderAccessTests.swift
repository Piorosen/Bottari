import Foundation
import Testing
@testable import BottariCore

/// A disk image mounted inside a scratch folder, hidden from Finder, to
/// plug in and pull out like a USB disk. Pulled out, the image file is
/// replaced by a copy: resolving a bookmark finds and mounts the file it was
/// made on, even moved, and a USB disk that is not there cannot be.
private struct ScratchDisk {
    let image: URL
    let away: URL
    let mountPoint: URL

    init(in folder: URL) throws {
        image = folder.appending(path: "disk.dmg")
        away = folder.appending(path: "unplugged.dmg")
        mountPoint = folder.appending(path: "disk")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Self.hdiutil(["create", "-quiet", "-size", "4m", "-fs", "APFS", "-volname", "BottariTest", image.path])
        try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path])
    }

    func plugIn() throws {
        try FileManager.default.moveItem(at: away, to: image)
        try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path])
    }

    func pullOut() throws {
        try Self.hdiutil(["detach", "-quiet", mountPoint.path])
        try Data(contentsOf: image).write(to: away)
        try FileManager.default.removeItem(at: image)
    }

    static let isAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")

    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
    }
}

@Suite(.serialized) struct FolderAccessTests {
    /// In /private/var, as resolved bookmarks give it, not the /var link.
    func scratchFolder() throws -> URL {
        let temp = try URL(fileURLWithPath: NSTemporaryDirectory()).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        let folder = URL(fileURLWithPath: try #require(temp)).appending(path: "FolderAccess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A folder allowed on a disk that is not plugged in at the next launch,
    /// nor while another folder is allowed, is allowed again once it is.
    @Test(.enabled(if: ScratchDisk.isAvailable), .timeLimit(.minutes(1)))
    func foldersOnADiskThatIsNotPluggedInStayAllowed() throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "io.github.piorosen.bottari.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let disk = try ScratchDisk(in: scratch)
        var pluggedIn = true
        defer { if pluggedIn { try? disk.pullOut() } }
        let onDisk = disk.mountPoint.appending(path: "photos")
        let onMac = scratch.appending(path: "documents")
        for folder in [onDisk, onMac] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        FolderAccess(defaults: defaults, sandboxed: true).remember(onDisk)
        try disk.pullOut()
        pluggedIn = false
        let withoutTheDisk = FolderAccess(defaults: defaults, sandboxed: true)
        withoutTheDisk.restore()
        withoutTheDisk.remember(onMac)
        try disk.plugIn()
        pluggedIn = true

        let pluggedInAgain = FolderAccess(defaults: defaults, sandboxed: true)
        pluggedInAgain.restore()
        #expect(pluggedInAgain.paths == [RemotePath(onDisk.path), RemotePath(onMac.path)].sorted { $0.string < $1.string })
    }

    /// A folder that is gone from a disk that is there is forgotten.
    @Test(.timeLimit(.minutes(1)))
    func foldersThatAreGoneAreForgotten() throws {
        let scratch = try scratchFolder()
        let folder = scratch.appending(path: "old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "io.github.piorosen.bottari.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        FolderAccess(defaults: defaults, sandboxed: true).remember(folder)
        try FileManager.default.removeItem(at: folder)
        FolderAccess(defaults: defaults, sandboxed: true).restore()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let later = FolderAccess(defaults: defaults, sandboxed: true)
        later.restore()
        #expect(later.paths == [])
    }
}
