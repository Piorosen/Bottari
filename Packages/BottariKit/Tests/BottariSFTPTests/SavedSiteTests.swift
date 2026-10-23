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
        Host secure
          HostName secure.example.com
          IdentityAgent ~/agent.sock
        """,
        directory: "/Users/me/.ssh",
        home: "/Users/me",
        localUser: "me"
    )

    func fileExists(_ path: String) -> Bool {
        path == "/Users/me/.ssh/id_ed25519"
    }

    @Test func importPicksAuthenticationLikeSsh() {
        let (sites, added) = SiteStore.importing(config, into: [], defaultUser: "me", fileExists: fileExists)

        #expect(added.map(\.name) == ["prod-web", "nas", "secure"])
        #expect(sites == added)
        let prod = added[0]
        #expect(prod.endpoint == SFTPEndpoint(host: "203.0.113.10", username: "deploy"))
        #expect(prod.authentication == .keyFile(path: "/Users/me/.ssh/id_ed25519"))
        #expect(prod.proxyJump == ["bastion"])
        #expect(prod.sshConfigAlias == "prod-web")
        #expect(added[1].endpoint == SFTPEndpoint(host: "nas.local", port: 2222, username: "me"))
        #expect(added[1].authentication == .agent(socket: nil))
        #expect(added[2].authentication == .agent(socket: "/Users/me/agent.sock"))
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
            SavedSite(name: "prod-web", endpoint: SFTPEndpoint(host: "203.0.113.10", username: "deploy"), authentication: .agent(socket: nil), tag: .prod),
            SavedSite(name: "nas", endpoint: SFTPEndpoint(host: "nas.local", port: 2222, username: "admin"), authentication: .password, startPath: "/volume1", readOnly: true),
        ]
        try store.save(sites)

        #expect(try store.load() == sites)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains("password\":\""))
    }

    @Test func prodSitesConfirmWritesByDefault() {
        let endpoint = SFTPEndpoint(host: "h", username: "u")
        #expect(SavedSite(name: "p", endpoint: endpoint, authentication: .password, tag: .prod).confirmsWrites)
        #expect(!SavedSite(name: "d", endpoint: endpoint, authentication: .password, tag: .dev).confirmsWrites)
        #expect(!SavedSite(name: "p", endpoint: endpoint, authentication: .password, tag: .prod, confirmsWrites: false).confirmsWrites)
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
