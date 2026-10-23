#if DEBUG
import BottariSFTP
import Foundation

extension SiteLibrary {
    /// The design's sample connections, saved to a temporary folder with
    /// secrets in memory, so previews never touch the real list or Keychain.
    static func preview() -> SiteLibrary {
        let library = SiteLibrary(
            store: SiteStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "bottari-preview-\(UUID().uuidString)/sites.json")),
            secrets: InMemorySecretStore(),
            loadSSHConfig: {
                SSHConfig(
                    text: """
                    Host bastion
                      HostName bastion.example.com
                      User me
                    Host gpu-box
                      HostName 10.0.4.21
                      User ml
                      ProxyJump bastion
                    Host staging-web
                      HostName 10.0.2.30
                      User deploy
                      ProxyJump bastion
                    """,
                    directory: "/Users/me/.ssh",
                    home: "/Users/me",
                    localUser: "me"
                )
            }
        )
        for site in SavedSite.previews {
            library.add(site)
        }
        return library
    }
}

extension SavedSite {
    static let previews = [
        SavedSite(
            name: "prod-web",
            endpoint: SFTPEndpoint(host: "203.0.113.10", username: "deploy"),
            authentication: .agent(socket: nil),
            proxyJump: ["bastion"],
            tag: .prod,
            startPath: "/var/www/site"
        ),
        SavedSite(
            name: "dev-api",
            endpoint: SFTPEndpoint(host: "dev-api.internal", username: "deploy"),
            authentication: .keyFile(path: "~/.ssh/id_ed25519"),
            proxyJump: ["bastion"],
            tag: .dev,
            startPath: "~/api"
        ),
        SavedSite(
            name: "home-nas",
            endpoint: SFTPEndpoint(host: "nas.local", port: 2222, username: "admin"),
            authentication: .password,
            tag: .personal,
            startPath: "/volume1/photos"
        ),
        SavedSite(
            name: "backup-01",
            endpoint: SFTPEndpoint(host: "10.0.9.5", username: "backup"),
            authentication: .keyFile(path: "~/.ssh/backup_ed25519"),
            proxyJump: ["bastion"],
            readOnly: true
        ),
    ]
}
#endif
