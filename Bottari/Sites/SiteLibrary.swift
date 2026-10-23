import AppKit
import BottariCloud
import BottariCore
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

    /// The list as another Mac left it. Secrets stay in this Mac's Keychain.
    func replaceAll(with sites: [SavedSite]) {
        guard sites != self.sites else { return }
        self.sites = sites
        recentlyImported = []
        persist()
        reloadSSHConfig()
    }

    func remove(_ id: SavedSite.ID) {
        guard let site = site(id) else { return }
        sites.removeAll { $0.id == id }
        recentlyImported.remove(id)
        for key in [site.passwordKey, site.passphraseKey, site.screenPasswordKey, site.s3SecretKey, site.googleSignInKey, site.googleClientSecretKey] {
            try? secrets.setSecret(nil, for: key)
        }
        persist()
        reloadSSHConfig()
    }

    /// Opens an SFTP connection to `site`. `typedSecrets` (Keychain key → value)
    /// were just typed by the user: they win over stored ones, and are stored
    /// once the connection works.
    /// Opens whatever the site is: an SFTP server, an S3 bucket or a Google Drive.
    func connect(_ site: SavedSite, typedSecrets: [String: String] = [:]) async throws -> any FileProvider {
        switch site.kind {
        case .sftp:
            return try await connectSFTP(site, typedSecrets: typedSecrets)
        case .s3(let settings):
            return try await connectS3(site, settings, typedSecrets: typedSecrets)
        case .googleDrive(let settings):
            return try await connectDrive(site, settings)
        }
    }

    private func connectS3(_ site: SavedSite, _ settings: SavedSite.S3Settings, typedSecrets: [String: String]) async throws -> S3Provider {
        let stored = secrets
        let key = site.s3SecretKey
        let secret = try await Task.detached { try typedSecrets[key] ?? stored.secret(for: key) }.value
        guard let secret, !secret.isEmpty else { throw CloudConnectError("S3 비밀 키가 저장되어 있지 않아요.") }
        let provider = S3Provider(
            configuration: S3Configuration(bucket: settings.bucket, region: settings.region, endpoint: settings.endpoint, accessKey: settings.accessKey, usesPathStyle: settings.usesPathStyle),
            secretKey: secret,
            displayName: site.name
        )
        // Fail here, with the reason, rather than in an empty pane.
        _ = try await provider.list(.root)
        if let typed = typedSecrets[key] {
            await Task.detached { try? stored.setSecret(typed, for: key) }.value
        }
        return provider
    }

    private func connectDrive(_ site: SavedSite, _ settings: SavedSite.DriveSettings) async throws -> GoogleDriveProvider {
        let stored = secrets
        let key = site.googleSignInKey
        guard let saved = try await Task.detached(operation: { try stored.secret(for: key) }).value, let archived = Data(base64Encoded: saved) else {
            throw CloudConnectError("Google 계정으로 로그인해 주세요. 연결 관리에서 로그인할 수 있어요.")
        }
        let authorization = try GoogleAuthorization(archived: archived)
        let provider = GoogleDriveProvider(
            account: settings.account.isEmpty ? authorization.account : settings.account,
            tokens: authorization,
            exportFormat: DriveExportFormat(rawValue: settings.exportFormat) ?? .office,
            displayName: site.name
        )
        _ = try await provider.list(.root)
        // Tokens may have been refreshed; keep the newest.
        let fresh = authorization.archived.base64EncodedString()
        await Task.detached { try? stored.setSecret(fresh, for: key) }.value
        return provider
    }

    /// Opens Google's sign-in page and keeps the result in the Keychain.
    func signInToGoogle(_ site: SavedSite, clientSecret: String?) async throws {
        guard case .googleDrive(var settings) = site.kind else { return }
        let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        let storedSecret = try? secrets.secret(for: site.googleClientSecretKey)
        let secret = clientSecret?.isEmpty == false ? clientSecret : storedSecret
        let authorization = try await GoogleAuthorization.signIn(clientID: settings.clientID, clientSecret: secret, presentingWindow: window)
        try secrets.setSecret(authorization.archived.base64EncodedString(), for: site.googleSignInKey)
        if let clientSecret, !clientSecret.isEmpty {
            try? secrets.setSecret(clientSecret, for: site.googleClientSecretKey)
        }
        settings.account = authorization.account
        var signedIn = site
        signedIn.kind = .googleDrive(settings)
        update(signedIn)
    }

    func signOutOfGoogle(_ site: SavedSite) {
        guard case .googleDrive(var settings) = site.kind else { return }
        try? secrets.setSecret(nil, for: site.googleSignInKey)
        settings.account = ""
        var signedOut = site
        signedOut.kind = .googleDrive(settings)
        update(signedOut)
    }

    /// A running Bottari-only tunnel that covers the site's host adds its
    /// server as the first jump, unless `takingDetours` is false (the tunnel's own connection).
    func connectSFTP(_ site: SavedSite, typedSecrets: [String: String] = [:], takingDetours: Bool = true) async throws -> SFTPFileProvider {
        let sites = sites
        let sshConfig = sshConfig
        let stored = secrets
        let detour = takingDetours ? TunnelStore.shared.detour(for: site) : nil
        // Key files and the Keychain are read off the main thread: the Keychain
        // may stop to ask the user for permission.
        var plan = try await Task.detached {
            try site.connectionPlan(sites: sites, sshConfig: sshConfig, secrets: TypedSecrets(typed: typedSecrets, stored: stored))
        }.value
        if let detour {
            let via = try await Task.detached {
                try detour.connectionPlan(sites: sites, sshConfig: sshConfig, secrets: stored)
            }.value
            plan.hops = via.hops + [SSHHop(endpoint: via.endpoint, credential: via.credential)] + plan.hops
        }
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
            settingsChanged()
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

struct CloudConnectError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
