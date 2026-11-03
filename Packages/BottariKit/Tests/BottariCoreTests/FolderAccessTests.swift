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
        try eject()
        try Data(contentsOf: image).write(to: away)
        try FileManager.default.removeItem(at: image)
    }

    /// Unmounts the disk and leaves the image where it is, like a disk image
    /// the user opened once or a server share: something that can be mounted.
    func eject() throws {
        try Self.hdiutil(["detach", "-quiet", mountPoint.path])
    }

    /// Where the image is mounted now, by whatever mounted it.
    func mountPoints() throws -> [String] {
        let info = try PropertyListSerialization.propertyList(from: Self.hdiutil(["info", "-plist"]), format: nil) as? [String: Any]
        return (info?["images"] as? [[String: Any]] ?? [])
            .filter { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == image.resolvingSymlinksInPath() }
            .flatMap { ($0["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String } }
    }

    func ejectEverywhere() throws {
        for point in try mountPoints() {
            try Self.hdiutil(["detach", "-quiet", point])
        }
    }

    static let isAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")

    @discardableResult
    private static func hdiutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return data
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

    /// Launching opens the folders allowed before; one on a disk that is not
    /// mounted stays that way, rather than Bottari mounting it.
    @Test(.enabled(if: ScratchDisk.isAvailable), .timeLimit(.minutes(1)))
    func launchingMountsNoDisk() throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "io.github.piorosen.bottari.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let disk = try ScratchDisk(in: scratch)
        defer { try? disk.ejectEverywhere() }
        let onDisk = disk.mountPoint.appending(path: "photos")
        try FileManager.default.createDirectory(at: onDisk, withIntermediateDirectories: true)
        FolderAccess(defaults: defaults, sandboxed: true).remember(onDisk)
        try disk.eject()

        FolderAccess(defaults: defaults, sandboxed: true).restore()

        let mounted = try disk.mountPoints()
        #expect(mounted == [])
    }

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
