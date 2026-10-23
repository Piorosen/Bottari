import BottariSFTP
import BottariTransfer
import Foundation

/// App-wide services shared by every window.
enum AppServices {
    private static let supportDirectory = URL.applicationSupportDirectory.appending(path: "Bottari")

    /// Host keys the user has trusted, kept between launches like `~/.ssh/known_hosts`.
    static let knownHosts = KnownHosts(fileURL: supportDirectory.appending(path: "known_hosts.json"))

    static let sites = SiteLibrary(
        store: SiteStore(fileURL: supportDirectory.appending(path: "sites.json")),
        secrets: KeychainSecretStore(service: "io.github.piorosen.bottari")
    )

    static let transfers: TransferQueue = {
        let queue = TransferQueue()
        queue.maxConcurrentTransfers = TransferSettings.maxConcurrentTransfers
        queue.verifiesChecksums = TransferSettings.verifiesChecksums
        queue.onJobsChanged = {
            connections.closeUnused()
            NotificationCenter.default.post(name: .transfersChanged, object: nil)
        }
        return queue
    }()

    static let connections = ConnectionKeeper()

    /// Local copies of server files for previews, viewers and editors.
    static let fileCache = FileCache(
        directory: URL.cachesDirectory.appending(path: "io.github.piorosen.bottari/files")
    )

    static let clipboard = FileClipboard()
}

extension Notification.Name {
    /// A transfer ended or was removed; panes showing its folders reload.
    static let transfersChanged = Notification.Name("BottariTransfersChanged")
}
