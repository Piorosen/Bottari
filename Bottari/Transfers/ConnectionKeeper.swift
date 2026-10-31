import BottariCore
import BottariSFTP
import Foundation

/// Closes server connections once nothing needs them. A pane that moves on
/// from a server hands its connection here; it stays open while a transfer or
/// the clipboard still refers to it.
final class ConnectionKeeper {
    private var parked: [SFTPFileProvider] = []

    func release(_ provider: any FileProvider) async {
        guard let server = provider as? SFTPFileProvider else { return }
        if isInUse(server) {
            parked.append(server)
        } else {
            await server.disconnect()
        }
    }

    /// Takes a connection opened for something other than a pane, such as a
    /// resumed transfer or a bundle preset, to close once nothing uses it.
    func adopt(_ provider: any FileProvider) {
        guard let server = provider as? SFTPFileProvider, !parked.contains(where: { $0.connectionID == server.connectionID }) else { return }
        parked.append(server)
        closeUnused()
    }

    /// Closes parked connections that nothing uses any more.
    func closeUnused() {
        let unused = parked.filter { !isInUse($0) }
        parked.removeAll { server in unused.contains { $0.connectionID == server.connectionID } }
        for server in unused {
            Task { await server.disconnect() }
        }
    }

    private func isInUse(_ server: SFTPFileProvider) -> Bool {
        let uses = { (provider: any FileProvider) in
            (provider as? SFTPFileProvider)?.connectionID == server.connectionID
        }
        let transferring = AppServices.transfers.unfinishedJobs.contains { uses($0.source.provider) || uses($0.destination.provider) }
        let onClipboard = AppServices.clipboard.content.map { uses($0.provider) } ?? false
        return transferring || onClipboard || ExternalEdits.shared.uses(server) || BottariBundle.shared.uses(server) || Viewers.uses(server)
    }
}
