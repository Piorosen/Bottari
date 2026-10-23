import Foundation
import Testing
@testable import BottariCore

@Suite struct ThreeWaySyncTests {
    struct Site: Codable, Identifiable, Equatable {
        let id: Int
        var port: Int
    }

    let base = [Site(id: 1, port: 22), Site(id: 2, port: 22), Site(id: 3, port: 22)]

    @Test func oneSidedChangesMerge() {
        let local = [Site(id: 1, port: 2222), Site(id: 2, port: 22), Site(id: 3, port: 22), Site(id: 4, port: 22)]
        let remote = [Site(id: 1, port: 22), Site(id: 2, port: 8022), Site(id: 5, port: 22)]

        let result = ThreeWaySync.merge(base: base, local: local, remote: remote)

        // 1 changed here, 2 changed there, 3 removed there, 4 added here, 5 added there.
        let expected = [Site(id: 1, port: 2222), Site(id: 2, port: 8022), Site(id: 4, port: 22), Site(id: 5, port: 22)]
        #expect(result.merged == expected)
        #expect(result.remote == expected)
        #expect(result.base == expected)
        #expect(result.conflicts.isEmpty)
    }

    @Test func changesOnBothSidesConflict() {
        let local = [Site(id: 1, port: 22), Site(id: 2, port: 2200), Site(id: 3, port: 22)]
        let remote = [Site(id: 1, port: 22), Site(id: 2, port: 2222)]

        let result = ThreeWaySync.merge(base: base, local: local, remote: remote)

        #expect(result.conflicts.map(\.id) == [2])
        #expect(result.conflicts.first?.local?.port == 2200 && result.conflicts.first?.remote?.port == 2222)
        // Each side keeps its own until resolved; 3 was untouched here, removed there.
        #expect(result.merged == [Site(id: 1, port: 22), Site(id: 2, port: 2200)])
        #expect(result.remote == [Site(id: 1, port: 22), Site(id: 2, port: 2222)])
        #expect(result.base == [Site(id: 1, port: 22), Site(id: 2, port: 22)])
    }

    @Test func editedHereRemovedThereIsAConflict() {
        let local = [Site(id: 1, port: 2222), Site(id: 2, port: 22), Site(id: 3, port: 22)]
        let remote = [Site(id: 2, port: 22), Site(id: 3, port: 22)]
        let result = ThreeWaySync.merge(base: base, local: local, remote: remote)
        #expect(result.conflicts.first?.remote == nil)
        #expect(result.merged.map(\.id) == [1, 2, 3])
        #expect(result.remote.map(\.id) == [2, 3])
    }

    @Test func firstSyncTakesEverything() {
        let result = ThreeWaySync.merge(base: [Site](), local: [Site(id: 1, port: 22)], remote: [Site(id: 2, port: 22)])
        #expect(result.merged.map(\.id) == [1, 2])
        #expect(result.conflicts.isEmpty)
    }
}

@Suite struct SyncFolderTests {
    typealias Site = ThreeWaySyncTests.Site

    struct Theme: Codable, Identifiable, Equatable {
        var id: String { name }
        var name: String
        var accent: String
    }

    let root = FileManager.default.temporaryDirectory.appending(path: "bottari-sync-\(UUID().uuidString)")
    var cloud: URL { root.appending(path: "iCloud/Bottari") }

    /// One Mac: the shared folder, and its own agreed state.
    func mac(_ name: String) -> SyncFolder {
        SyncFolder(folder: cloud, baseFolder: root.appending(path: "\(name)/sync-base"))
    }

    @Test func twoMacsShareChanges() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = mac("a"), b = mac("b")

        // A goes first and writes its list; B adds its own.
        #expect(try a.sync("sites.json", local: [Site(id: 1, port: 22)]).items.map(\.id) == [1])
        #expect(try b.sync("sites.json", local: [Site(id: 2, port: 22)]).items.map(\.id) == [2, 1])
        #expect(try a.sync("sites.json", local: [Site(id: 1, port: 22)]).items.map(\.id) == [1, 2])

        // A changes 1, B removes 2: both arrive.
        _ = try a.sync("sites.json", local: [Site(id: 1, port: 2222), Site(id: 2, port: 22)])
        let onB = try b.sync("sites.json", local: [Site(id: 1, port: 22)])
        #expect(onB.items == [Site(id: 1, port: 2222)])
        #expect(try a.sync("sites.json", local: [Site(id: 1, port: 2222), Site(id: 2, port: 22)]).items == [Site(id: 1, port: 2222)])
        // The file stays readable JSON.
        let text = try String(contentsOf: cloud.appending(path: "sites.json"), encoding: .utf8)
        #expect(text.contains("\"port\" : 2222"))
    }

    @Test func conflictsWaitForAnAnswer() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = mac("a"), b = mac("b")
        _ = try a.sync("sites.json", local: [Site(id: 1, port: 22)])
        _ = try b.sync("sites.json", local: [Site(id: 1, port: 22)])

        _ = try a.sync("sites.json", local: [Site(id: 1, port: 2200)])
        let first = try b.sync("sites.json", local: [Site(id: 1, port: 2222)])
        #expect(first.conflicts.count == 1)
        #expect(first.items == [Site(id: 1, port: 2222)])
        // Still a conflict until B decides; A, whose version is the shared one, keeps it meanwhile.
        #expect(try b.sync("sites.json", local: [Site(id: 1, port: 2222)]).conflicts.count == 1)
        let meanwhile = try a.sync("sites.json", local: [Site(id: 1, port: 2200)])
        #expect(meanwhile.conflicts.isEmpty && meanwhile.items == [Site(id: 1, port: 2200)])

        // B keeps its own: agreeing on A's version makes B's the one change.
        try b.setBase("sites.json", [Site(id: 1, port: 2200)])
        let kept = try b.sync("sites.json", local: [Site(id: 1, port: 2222)])
        #expect(kept.conflicts.isEmpty && kept.items == [Site(id: 1, port: 2222)])
        #expect(try a.sync("sites.json", local: [Site(id: 1, port: 2200)]).items == [Site(id: 1, port: 2222)])
    }

    @Test func aDeletedFileIsWrittenAgainNotEmptied() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = mac("a")
        _ = try a.sync("sites.json", local: [Site(id: 1, port: 22)])
        try FileManager.default.removeItem(at: cloud)

        #expect(try a.sync("sites.json", local: [Site(id: 1, port: 22)]).items.map(\.id) == [1])
        #expect(FileManager.default.fileExists(atPath: cloud.appending(path: "sites.json").path))
    }

    @Test func aBrokenFileIsLeftAlone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = mac("a")
        _ = try a.sync("sites.json", local: [Site(id: 1, port: 22)])
        try Data("{ not json".utf8).write(to: cloud.appending(path: "sites.json"))

        #expect(throws: SyncFolder.Unreadable.self) { try a.sync("sites.json", local: [Site(id: 1, port: 22)]) }
        #expect(try String(contentsOf: cloud.appending(path: "sites.json"), encoding: .utf8) == "{ not json")
    }

    @Test func singleValues() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = mac("a"), b = mac("b")
        _ = try a.sync("keymap.json", value: "finder")
        #expect(try b.sync("keymap.json", value: "finder").value == "finder")
        _ = try a.sync("keymap.json", value: "commander")
        #expect(try b.sync("keymap.json", value: "finder").value == "commander")
        #expect(try String(contentsOf: cloud.appending(path: "keymap.json"), encoding: .utf8) == "\"commander\"")

        _ = try a.sync("keymap.json", value: "vim")
        let clash = try b.sync("keymap.json", value: "finder-custom")
        #expect(clash.conflict?.local == "finder-custom" && clash.conflict?.remote == "vim")
    }

    @Test func oneFilePerItemInADirectory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = mac("a"), b = mac("b")
        _ = try a.sync(directory: "themes", local: [Theme(name: "종이", accent: "#3651C9"), Theme(name: "쪽빛 밤", accent: "#0F7C78")])
        let files = try FileManager.default.contentsOfDirectory(atPath: cloud.appending(path: "themes").path).sorted()
        #expect(files == ["종이.json", "쪽빛 밤.json"])

        // A theme dropped into the folder by hand arrives; one removed there goes.
        let dropped = cloud.appending(path: "themes/dropped.json")
        try JSONEncoder().encode(Theme(name: "모시", accent: "#9A6700")).write(to: dropped)
        try FileManager.default.removeItem(at: cloud.appending(path: "themes/종이.json"))
        let onA = try a.sync(directory: "themes", local: [Theme(name: "종이", accent: "#3651C9"), Theme(name: "쪽빛 밤", accent: "#0F7C78")])
        #expect(onA.items.map(\.name) == ["쪽빛 밤", "모시"])

        // B changes the dropped one; it is written back to the same file.
        _ = try b.sync(directory: "themes", local: [Theme]())
        _ = try b.sync(directory: "themes", local: [Theme(name: "쪽빛 밤", accent: "#0F7C78"), Theme(name: "모시", accent: "#B0306A")])
        let reread = try JSONDecoder().decode(Theme.self, from: Data(contentsOf: dropped))
        #expect(reread.accent == "#B0306A")
    }
}
