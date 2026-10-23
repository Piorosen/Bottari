import BottariSFTP
import Foundation
import Observation

/// The user's saved connections. The list lives in Application Support;
/// passwords and key passphrases live in the Keychain.
@Observable
final class SiteLibrary {
    private(set) var sites: [SavedSite] = []
    /// `~/.ssh/config` hosts that are not saved yet.
    private(set) var importableHosts: [SSHConfig.Host] = []
    /// Sites added by the last import, marked "가져옴" in the list.
    private(set) var recentlyImported: Set<SavedSite.ID> = []
    /// Why the list could not be read or written, if it could not.
    private(set) var storageError: String?

    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored private let store: SiteStore
    @ObservationIgnored private let loadSSHConfig: () -> SSHConfig
    @ObservationIgnored private var sshConfig = SSHConfig(text: "", directory: "")

    init(store: SiteStore, secrets: any SecretStore, loadSSHConfig: @escaping () -> SSHConfig = { SSHConfig.load() }) {
        self.store = store
        self.secrets = secrets
        self.loadSSHConfig = loadSSHConfig
        do {
            sites = try store.load()
        } catch {
            storageError = "저장된 연결을 읽지 못했어요: \(error.localizedDescription)"
        }
        reloadSSHConfig()
    }

    func site(_ id: SavedSite.ID) -> SavedSite? {
        sites.first { $0.id == id }
    }

    /// Reads `~/.ssh/config` again, e.g. when the connection manager opens.
    func reloadSSHConfig() {
        sshConfig = loadSSHConfig()
        let saved = Set(sites.compactMap(\.sshConfigAlias))
        importableHosts = sshConfig.hosts.filter { !saved.contains($0.alias) }
    }

    /// Saves every importable `~/.ssh/config` host and returns the new sites.
    @discardableResult
    func importSSHConfig() -> [SavedSite] {
        let result = SiteStore.importing(sshConfig, into: sites)
        sites = result.sites
        recentlyImported = Set(result.added.map(\.id))
        importableHosts = []
        persist()
        return result.added
    }

    /// Names a jump host can refer to: saved sites, then `~/.ssh/config` aliases.
    var jumpHostNames: [String] {
        var seen = Set<String>()
        return (sites.map(\.name) + sshConfig.aliases).filter { seen.insert($0).inserted }
    }

    @discardableResult
    func add(_ site: SavedSite = SavedSite(
        name: "새 서버",
        endpoint: SFTPEndpoint(host: "", username: NSUserName()),
        authentication: .agent(socket: nil)
    )) -> SavedSite {
        sites.append(site)
        persist()
        return site
    }

    func update(_ site: SavedSite) {
        guard let index = sites.firstIndex(where: { $0.id == site.id }), sites[index] != site else { return }
        sites[index] = site
        persist()
    }

    func remove(_ id: SavedSite.ID) {
        guard let site = site(id) else { return }
        sites.removeAll { $0.id == id }
        recentlyImported.remove(id)
        try? secrets.setSecret(nil, for: site.passwordKey)
        try? secrets.setSecret(nil, for: site.passphraseKey)
        persist()
        reloadSSHConfig()
    }

    /// Opens an SFTP connection to `site`. `typedSecrets` (Keychain key → value)
    /// were just typed by the user: they win over stored ones, and are stored
    /// once the connection works.
    func connect(_ site: SavedSite, typedSecrets: [String: String] = [:]) async throws -> SFTPFileProvider {
        let sites = sites
        let sshConfig = sshConfig
        let stored = secrets
        // Key files and the Keychain are read off the main thread: the Keychain
        // may stop to ask the user for permission.
        let plan = try await Task.detached {
            try site.connectionPlan(sites: sites, sshConfig: sshConfig, secrets: TypedSecrets(typed: typedSecrets, stored: stored))
        }.value
        let provider = try await SFTPFileProvider.connect(
            to: plan.endpoint,
            credential: plan.credential,
            hostKeys: .knownHosts(AppServices.knownHosts),
            via: plan.hops,
            displayName: site.name
        )
        if !typedSecrets.isEmpty {
            await Task.detached {
                for (key, value) in typedSecrets {
                    try? stored.setSecret(value, for: key)
                }
            }.value
        }
        return provider
    }

    private func persist() {
        do {
            try store.save(sites)
            storageError = nil
        } catch {
            storageError = "연결 목록을 저장하지 못했어요: \(error.localizedDescription)"
        }
    }
}

/// Secrets the user just typed, in front of the stored ones.
private struct TypedSecrets: SecretStore {
    let typed: [String: String]
    let stored: any SecretStore

    func secret(for key: String) throws -> String? {
        try typed[key] ?? stored.secret(for: key)
    }

    func setSecret(_ value: String?, for key: String) throws {
        try stored.setSecret(value, for: key)
    }
}
