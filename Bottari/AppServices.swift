import BottariSFTP
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
}
