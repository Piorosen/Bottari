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
            storageError = String(localized: "저장된 연결을 읽을 수 없습니다: \(error.localizedDescription)")
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
        // From this Mac's own ~/.ssh/config, so its commands are this Mac's too.
        for site in result.added {
            if let command = site.proxyCommand { Self.allowProxyCommand(command, for: site.id) }
        }
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
        name: String(localized: "새 서버"),
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

    /// The list as another Mac left it. Secrets stay in this Mac's Keychain,
    /// except those of sites the other Mac deleted.
    func replaceAll(with sites: [SavedSite]) {
        guard sites != self.sites else { return }
        let kept = Set(sites.map(\.id))
        for gone in self.sites where !kept.contains(gone.id) {
            forgetSecrets(of: gone)
        }
        self.sites = sites
        recentlyImported = []
        persist()
        reloadSSHConfig()
    }

    func remove(_ id: SavedSite.ID) {
        guard let site = site(id) else { return }
        sites.removeAll { $0.id == id }
        recentlyImported.remove(id)
        forgetSecrets(of: site)
        persist()
        reloadSSHConfig()
    }

    private func forgetSecrets(of site: SavedSite) {
        for key in [site.passwordKey, site.passphraseKey, site.screenPasswordKey, site.screenUsernameKey, site.s3SecretKey, site.googleSignInKey, site.googleClientSecretKey] {
            try? secrets.setSecret(nil, for: key)
        }
    }

    /// Opens whatever the site is: an SFTP server, an S3 bucket or a Google Drive.
    /// `typedSecrets` (Keychain key → value) were just typed by the user: they
    /// win over stored ones, and are stored once the connection works unless
    /// `keepingTypedSecrets` is false.
    func connect(_ site: SavedSite, typedSecrets: [String: String] = [:], keepingTypedSecrets: Bool = true) async throws -> any FileProvider {
        switch site.kind {
        case .sftp:
            return try await connectSFTP(site, typedSecrets: typedSecrets, keepingTypedSecrets: keepingTypedSecrets)
        case .s3(let settings):
            return try await connectS3(site, settings, typedSecrets: typedSecrets)
        case .googleDrive(let settings):
            return try await connectDrive(site, settings)
        }
    }

    private func connectS3(_ site: SavedSite, _ settings: SavedSite.S3Settings, typedSecrets: [String: String]) async throws -> S3Provider {
        let stored = secrets
        let key = site.s3SecretKey
        let secret = try await Task.detached { try typedSecrets[key] ?? stored.readableSecret(for: key) }.value
        guard let secret, !secret.isEmpty else { throw CloudConnectError(String(localized: "저장된 S3 비밀 키가 없습니다.")) }
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
        guard let saved = try await Task.detached(operation: { try stored.readableSecret(for: key) }).value, let archived = Data(base64Encoded: saved) else {
            throw CloudConnectError(String(localized: "Google 계정에 로그인되어 있지 않습니다. 연결 관리에서 로그인하십시오."))
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

    /// Opens Google's sign-in page and keeps the result in the Keychain. A
    /// site without a client of its own uses the one built into the app.
    func signInToGoogle(_ site: SavedSite, clientSecret: String?) async throws {
        guard case .googleDrive(var settings) = site.kind else { return }
        let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        let storedSecret = try? secrets.readableSecret(for: site.googleClientSecretKey)
        let ownClient = !settings.clientID.isEmpty
        guard let clientID = ownClient ? settings.clientID : GoogleClient.builtIn?.id else {
            throw CloudConnectError(String(localized: "OAuth 클라이언트 ID를 입력하십시오."))
        }
        let secret = clientSecret?.isEmpty == false ? clientSecret : ownClient ? storedSecret : GoogleClient.builtIn?.secret
        let authorization = try await GoogleAuthorization.signIn(clientID: clientID, clientSecret: secret, presentingWindow: window)
        try secrets.setSecret(authorization.archived.base64EncodedString(), for: site.googleSignInKey)
        googleSignIns += 1
        if let clientSecret, !clientSecret.isEmpty {
            try? secrets.setSecret(clientSecret, for: site.googleClientSecretKey)
        }
        settings.account = authorization.account
        var signedIn = site
        signedIn.kind = .googleDrive(settings)
        update(signedIn)
    }

    /// Forgets this Mac's sign-in. The account name stays: it is synced to
    /// the other Macs, which keep their own sign-ins.
    func signOutOfGoogle(_ site: SavedSite) {
        guard case .googleDrive = site.kind else { return }
        try? secrets.setSecret(nil, for: site.googleSignInKey)
        googleSignIns += 1
    }

    /// Whether this Mac holds a Google sign-in for the site. The account
    /// name alone does not say so: it arrives from other Macs through sync,
    /// the sign-in does not.
    func isSignedInToGoogle(_ site: SavedSite) -> Bool {
        _ = googleSignIns
        return ((try? secrets.secret(for: site.googleSignInKey)) ?? nil)?.isEmpty == false
    }

    /// Bumped by signing in or out, which the Keychain cannot tell views about.
    private var googleSignIns = 0

    /// A running Bottari-only tunnel that covers the site's host adds its
    /// server as the first jump, unless `takingDetours` is false (the tunnel's own connection).
    func connectSFTP(_ site: SavedSite, typedSecrets: [String: String] = [:], keepingTypedSecrets: Bool = true, takingDetours: Bool = true) async throws -> SFTPFileProvider {
        let sites = sites
        let sshConfig = sshConfig
        let stored = secrets
        let detour = takingDetours ? TunnelStore.shared.detour(for: site) : nil
        try confirmProxyCommands(on: [site] + (detour.map { [$0] } ?? []))
        // Key files and the Keychain are read off the main thread: the Keychain
        // may stop to ask the user for permission.
        var plan = try await Task.detached {
            try site.connectionPlan(sites: sites, sshConfig: sshConfig, secrets: TypedSecrets(typed: typedSecrets, stored: stored))
        }.value
        if let detour {
            let via = try await Task.detached {
                try detour.connectionPlan(sites: sites, sshConfig: sshConfig, secrets: stored)
            }.value
            plan = plan.through(via)
        }
        let provider = try await SFTPFileProvider.connect(
            to: plan.endpoint,
            credential: plan.credential,
            hostKeys: .knownHosts(AppServices.knownHosts),
            via: plan.hops,
            proxyCommand: plan.proxyCommand,
            displayName: site.name
        )
        if keepingTypedSecrets, !typedSecrets.isEmpty {
            await Task.detached {
                for (key, value) in typedSecrets {
                    do {
                        try stored.setSecret(value, for: key)
                    } catch {
                        Log.app.error("키체인에 저장하지 못함: \(key): \(error.localizedDescription)")
                    }
                }
            }.value
        }
        return provider
    }

    // MARK: - ProxyCommands from elsewhere

    /// ProxyCommands run as shell commands on this Mac, and sites arrive
    /// from other Macs through iCloud. A command runs only once it was typed
    /// or allowed here; this list stays on this Mac.
    private static let allowedProxyCommandsKey = "sites.allowedProxyCommands"

    static func allowProxyCommand(_ command: String, for site: SavedSite.ID) {
        var allowed = UserDefaults.standard.dictionary(forKey: allowedProxyCommandsKey) as? [String: String] ?? [:]
        allowed[site.uuidString] = command
        UserDefaults.standard.set(allowed, forKey: allowedProxyCommandsKey)
    }

    private static func isAllowed(_ command: String, for site: SavedSite.ID) -> Bool {
        (UserDefaults.standard.dictionary(forKey: allowedProxyCommandsKey) as? [String: String])?[site.uuidString] == command
    }

    /// Asks before running a ProxyCommand this Mac has not seen, for `sites`
    /// and the saved jump hosts they go through.
    private func confirmProxyCommands(on start: [SavedSite]) throws {
        var queue = start
        var seen = Set<SavedSite.ID>()
        while let next = queue.popLast() {
            guard seen.insert(next.id).inserted else { continue }
            queue += next.proxyJump.compactMap { name in sites.first { $0.name == name } }
            guard let command = next.proxyCommand?.trimmingCharacters(in: .whitespaces), !command.isEmpty,
                  !Self.isAllowed(command, for: next.id) else { continue }
            let alert = NSAlert()
            alert.messageText = String(localized: "‘\(next.name)’에 연결하려면 이 Mac에서 명령을 실행합니다")
            alert.informativeText = String(localized: "이 ProxyCommand는 이 Mac에서 입력한 것이 아닙니다(다른 Mac에서 동기화됨). 아는 명령일 때만 허락하십시오.") + "\n\n" + command
            alert.addButton(withTitle: String(localized: "취소"))
            alert.addButton(withTitle: String(localized: "허락하고 연결"))
            guard alert.runModal() == .alertSecondButtonReturn else {
                throw CloudConnectError(String(localized: "ProxyCommand 실행을 허락하지 않아 연결하지 않았습니다."))
            }
            Self.allowProxyCommand(command, for: next.id)
        }
    }

    private func persist() {
        do {
            try store.save(sites)
            storageError = nil
            settingsChanged()
        } catch {
            storageError = String(localized: "연결 목록을 저장할 수 없습니다: \(error.localizedDescription)")
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

/// The Google Cloud OAuth client a release build carries (Config/release.env),
/// so Google Drive works without each user making a client of their own.
enum GoogleClient {
    static let builtIn: (id: String, secret: String?)? = {
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ key: String) -> String? {
            guard let text = info[key] as? String, !text.isEmpty, !text.hasPrefix("$(") else { return nil }
            return text
        }
        return value("BottariGoogleClientID").map { ($0, value("BottariGoogleClientSecret")) }
    }()
}
