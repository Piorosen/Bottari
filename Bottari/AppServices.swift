import BottariSFTP
import Foundation

/// App-wide services shared by every window.
enum AppServices {
    /// Host keys the user has trusted, kept between launches like `~/.ssh/known_hosts`.
    static let knownHosts = KnownHosts(
        fileURL: URL.applicationSupportDirectory.appending(path: "Bottari/known_hosts.json")
    )
}
