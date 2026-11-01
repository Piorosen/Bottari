import BottariCore
import Foundation
import Testing
@testable import BottariSFTP

@Suite struct SavedSiteTests {
    let config = SSHConfig(
        text: """
        Host prod-web
          HostName 203.0.113.10
          User deploy
          IdentityFile ~/.ssh/missing
          IdentityFile ~/.ssh/id_ed25519
          ProxyJump bastion
        Host nas
          HostName nas.local
          Port 2222
        Host relayed
          HostName relayed.example.com
          ProxyCommand ssh -W %h:%p bastion
        Host piped
          HostName piped.example.com
          ProxyCommand cloudflared access ssh --hostname %h
        """,
        directory: "/Users/me/.ssh",
        home: "/Users/me",
        localUser: "me"
    )

    func fileExists(_ path: String) -> Bool {
        path == "/Users/me/.ssh/id_ed25519"
    }

    @Test func readsTheJumpHostOutOfAnSSHWRelay() {
        #expect(SavedSite.jumpHost(inProxyCommand: "ssh -W %h:%p bastion") == "bastion")
        #expect(SavedSite.jumpHost(inProxyCommand: "/usr/bin/ssh -q -W %h:%p deploy@bastion.example.com") == "deploy@bastion.example.com")
        #expect(SavedSite.jumpHost(inProxyCommand: "ssh bastion -W %h:%p") == "bastion")
        // Anything more than a plain relay needs the command itself, which Bottari does not run.
        #expect(SavedSite.jumpHost(inProxyCommand: "ssh -i ~/.ssh/other -W %h:%p bastion") == nil)
        #expect(SavedSite.jumpHost(inProxyCommand: "ssh -W %h:%p %r@bastion") == nil)
        #expect(SavedSite.jumpHost(inProxyCommand: "nc -X 5 -x proxy:1080 %h %p") == nil)
        #expect(SavedSite.jumpHost(inProxyCommand: "cloudflared access ssh --hostname %h") == nil)
    }

    @Test func importPicksAuthenticationLikeSsh() {
        let (sites, added) = SiteStore.importing(config, into: [], defaultUser: "me", fileExists: fileExists)

        #expect(added.map(\.name) == ["prod-web", "nas", "relayed", "piped"])
        #expect(sites == added)
        let prod = added[0]
        #expect(prod.endpoint == SFTPEndpoint(host: "203.0.113.10", username: "deploy"))
        #expect(prod.authentication == .keyFile(path: "/Users/me/.ssh/id_ed25519"))
        #expect(prod.proxyJump == ["bastion"])
        #expect(prod.sshConfigAlias == "prod-web")
        #expect(added[1].endpoint == SFTPEndpoint(host: "nas.local", port: 2222, username: "me"))
        #expect(added[1].authentication == .defaultKeys)
        // `ssh -W` through a jump host becomes that jump host; other commands are left out.
        #expect(added[2].proxyJump == ["bastion"])
        #expect(added[3].proxyJump.isEmpty)
    }

    @Test func importingAgainKeepsEditsAndAddsOnlyNewHosts() {
        var (sites, _) = SiteStore.importing(config, into: [], defaultUser: "me", fileExists: fileExists)
        sites[0].name = "운영 웹"
        sites[0].tag = .prod

        let again = SiteStore.importing(config, into: sites, defaultUser: "me", fileExists: fileExists)

        #expect(again.added.isEmpty)
        #expect(again.sites == sites)
    }

    @Test func storeRoundTripsThroughJSON() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sites-\(UUID().uuidString)/sites.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SiteStore(fileURL: url)
        #expect(try store.load().isEmpty)

        let sites = [
            SavedSite(name: "prod-web", endpoint: SFTPEndpoint(host: "203.0.113.10", username: "deploy"), authentication: .defaultKeys, tag: .prod),
            SavedSite(name: "nas", endpoint: SFTPEndpoint(host: "nas.local", port: 2222, username: "admin"), authentication: .password, startPath: "/volume1", readOnly: true,
                      remoteScreen: .init(kind: .appleScreenSharing)),
        ]
        try store.save(sites)

        #expect(try store.load() == sites)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains("password\":\""))
    }

    @Test func olderSiteFilesStillLoad() throws {
        let json = """
        [{"id":"8C9F4C0A-3E69-4B0B-9F6B-2C1E5B9A7D10","name":"old","endpoint":{"host":"h","port":22,"username":"u"},
          "authentication":{"password":{}},"tag":"prod"}]
        """
        let sites = try JSONDecoder().decode([SavedSite].self, from: Data(json.utf8))
        #expect(sites.first?.proxyJump == [])
        #expect(sites.first?.readOnly == false)
        #expect(sites.first?.confirmsWrites == true)
        #expect(sites.first?.remoteScreen == nil)
        #expect(sites.first?.isSFTP == true)
    }

    /// Sites saved while Bottari asked an SSH agent first load as default keys,
    /// and default keys are saved under that old name, so copies on either side read them.
    @Test func agentSitesLoadAsDefaultKeys() throws {
        let json = """
        [{"id":"8C9F4C0A-3E69-4B0B-9F6B-2C1E5B9A7D10","name":"old","endpoint":{"host":"h","port":22,"username":"u"},
          "authentication":{"agent":{"socket":"/tmp/agent.sock"}},"proxyCommand":"nc %h %p"}]
        """
        let site = try #require(try JSONDecoder().decode([SavedSite].self, from: Data(json.utf8)).first)
        #expect(site.authentication == .defaultKeys)
        let saved = try String(decoding: JSONEncoder().encode(site.authentication), as: UTF8.self)
        #expect(saved == #"{"agent":{}}"#)
    }

    @Test func cloudSitesRoundTrip() throws {
        var s3 = SavedSite.S3Settings()
        s3.bucket = "assets"
        s3.endpoint = "https://acct.r2.cloudflarestorage.com"
        let site = SavedSite(name: "r2", endpoint: SFTPEndpoint(host: "", username: ""), authentication: .password, kind: .s3(s3))
        let decoded = try JSONDecoder().decode(SavedSite.self, from: JSONEncoder().encode(site))
        #expect(decoded == site)
        #expect(!decoded.isSFTP)
    }

    @Test func prodSitesConfirmWritesByDefault() {
        let endpoint = SFTPEndpoint(host: "h", username: "u")
        #expect(SavedSite(name: "p", endpoint: endpoint, authentication: .password, tag: .prod).confirmsWrites)
        #expect(!SavedSite(name: "d", endpoint: endpoint, authentication: .password, tag: .dev).confirmsWrites)
        #expect(!SavedSite(name: "p", endpoint: endpoint, authentication: .password, tag: .prod, confirmsWrites: false).confirmsWrites)
    }

    @Test(arguments: [
        (nil, "/home/deploy"),
        ("~", "/home/deploy"),
        ("~/site/", "/home/deploy/site"),
        ("logs", "/home/deploy/logs"),
        ("/var/www", "/var/www"),
    ] as [(String?, String)])
    func startLocationExpandsTilde(startPath: String?, expected: String) {
        let site = SavedSite(name: "s", endpoint: SFTPEndpoint(host: "h", username: "deploy"), authentication: .password, startPath: startPath)
        #expect(site.startLocation(home: "/home/deploy") == RemotePath(expected))
    }

    @Test func secretKeysAreScopedToTheSite() {
        let site = SavedSite(name: "a", endpoint: SFTPEndpoint(host: "a", username: "u"), authentication: .password)
        #expect(site.passwordKey == "site.\(site.id.uuidString).password")
        #expect(site.passwordKey != site.passphraseKey)
    }

    @Test func inMemorySecretsSetAndRemove() throws {
        let secrets = InMemorySecretStore()
        try secrets.setSecret("hunter2", for: "k")
        #expect(try secrets.secret(for: "k") == "hunter2")
        try secrets.setSecret(nil, for: "k")
        #expect(try secrets.secret(for: "k") == nil)
    }

    /// Writes to the login Keychain, so it only runs when asked:
    /// `BOTTARI_KEYCHAIN_TESTS=1 swift test --filter SavedSiteTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTTARI_KEYCHAIN_TESTS"] == "1"))
    func keychainSetsReadsAndRemoves() throws {
        let store = KeychainSecretStore(service: "io.github.piorosen.bottari.tests")
        let key = "test.\(UUID().uuidString)"
        defer { try? store.setSecret(nil, for: key) }

        try store.setSecret("s3cret", for: key)
        #expect(try store.secret(for: key) == "s3cret")
        try store.setSecret("changed", for: key)
        #expect(try store.secret(for: key) == "changed")
        try store.setSecret(nil, for: key)
        #expect(try store.secret(for: key) == nil)
    }
}
