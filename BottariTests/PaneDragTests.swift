@testable import Bottari
import BottariCore
import BottariSFTP
import Foundation
import Testing

struct PaneDragTests {
    @Test func aDropTakesFilesFromWhereTheDragBegan() async throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let library = scratch.siteLibrary()
        let staging = StandInServer("staging", folder: try scratch.folder("staging"))
        let prod = StandInServer("prod", folder: try scratch.folder("prod"))
        let backup = StandInServer("backup", folder: try scratch.folder("backup"))
        for server in [staging, prod] {
            try Data("listen 80".utf8).write(to: server.folder.appending(path: "app.conf"))
        }
        let stagingSite = library.add(SavedSite(name: "staging", endpoint: SFTPEndpoint(host: "staging", username: "me"), authentication: .password))
        let prodSite = library.add(SavedSite(name: "prod", endpoint: SFTPEndpoint(host: "prod", username: "me"), authentication: .password))
        let backupSite = library.add(SavedSite(name: "backup", endpoint: SFTPEndpoint(host: "backup", username: "me"), authentication: .password, confirmsWrites: true))
        let workspace = Workspace(left: PaneModel(provider: staging, library: library), right: PaneModel(provider: backup, library: library))
        await workspace.left.switchProvider(to: staging, site: stagingSite)
        await workspace.right.switchProvider(to: backup, site: backupSite)
        let item = try #require(workspace.left.items.first { $0.name == "app.conf" })

        let dragged = workspace.dragProvider(for: item, from: .left)
        await workspace.left.switchProvider(to: prod, site: prodSite)
        #expect(workspace.drop([dragged], onto: .right))

        let transfer = try await confirmation(askedBy: workspace)
        #expect(transfer.sourceSite?.name == "staging")
        #expect(transfer.source.displayName == "staging")
        #expect(transfer.items.map(\.path) == [item.path])
        #expect(transfer.destinationSite?.name == "backup")
    }

    private func confirmation(askedBy workspace: Workspace) async throws -> TransferRequest {
        for _ in 0..<200 where workspace.pendingConfirmation == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(workspace.pendingConfirmation)
    }
}
