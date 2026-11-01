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

    /// Saves the importable `~/.ssh/config` hosts in `aliases` (every one
    /// when nil) and returns the new sites.
    @discardableResult
    func importSSHConfig(only aliases: Set<String>? = nil) -> [SavedSite] {
        let result = SiteStore.importing(sshConfig, into: sites, only: aliases)
        sites = result.sites
        recentlyImported = Set(result.added.map(\.id))
        let saved = Set(sites.compactMap(\.sshConfigAlias))
        importableHosts = sshConfig.hosts.filter { !saved.contains($0.alias) }
        persist()
        return result.added
    }

    /// The key files that `hosts` (not saved yet) and the saved sites log in
    /// with, each with what it says about itself and who uses it.
    func keyImportCandidates(for hosts: [SSHConfig.Host]) -> [KeyImportCandidate] {
        var users: [String: [String]] = [:]
        var order: [String] = []
        func add(_ path: String, _ user: String) {
            let path = UserHome.expand(path)
            if users[path] == nil { order.append(path) }
            users[path, default: []].append(user)
        }
        for site in sites {
            if case .keyFile(let path) = site.authentication { add(path, site.name) }
        }
        for host in hosts {
            // As importing picks it: the first IdentityFile that is there.
            if let path = host.identityFiles.first(where: { FileManager.default.fileExists(atPath: $0) }) { add(path, host.alias) }
        }
        return order.map { path in
            KeyImportCandidate(path: path, summary: SavedSite.readFile(path).flatMap { SSHKeyFileSummary(keyText: $0) }, users: users[path] ?? [])
        }
    }

    /// Copies each key file in `paths` into the Keychain for every saved site
    /// that logs in with it; those sites then use the copy (Bottari key), so
    /// ~/.ssh need not be allowed again. The files themselves stay as they are.
    /// Returns the files that could not be read.
    @discardableResult
    func importKeys(_ paths: Set<String>) -> [String] {
        var unreadable: [String] = []
        var texts: [String: String] = [:]
        for path in paths {
            if let text = SavedSite.readFile(path), SSHKeyFileSummary(keyText: text) != nil {
                texts[path] = text
            } else {
                unreadable.append(UserHome.abbreviate(path))
            }
        }
        for index in sites.indices {
            guard case .keyFile(let path) = sites[index].authentication, let text = texts[UserHome.expand(path)] else { continue }
            do {
                sites[index] = try sites[index].keepingKey(text, in: secrets)
                Log.app.info("\(sites[index].name): 키 파일을 키체인으로 가져옴 (\(UserHome.abbreviate(path)))")
            } catch {
                Log.app.error("\(sites[index].name): 키를 키체인에 넣지 못함: \(error.localizedDescription)")
                unreadable.append(UserHome.abbreviate(path))
            }
        }
        persist()
        return unreadable
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
        authentication: .defaultKeys
    )) -> SavedSite {
        sites.append(site)
        persist()
        return site
    }

    func update(_ site: SavedSite) {
        guard let index = sites.firstIndex(where: { $0.id == site.id }), sites[index] != site else { return }
        let previous = sites[index].name
        sites[index] = site
        // Jump hosts are named by site name: sites going through this one
        // follow it to its new name instead of losing their way. A name
        // erased while retyping it is remembered until the new one is in.
        var oldName = previous
        if previous.isEmpty, let erased = erasedNames.removeValue(forKey: site.id) { oldName = erased }
        if site.name.isEmpty {
            if !previous.isEmpty { erasedNames[site.id] = previous }
        } else if oldName != site.name, !oldName.isEmpty, !sites.contains(where: { $0.id != site.id && $0.name == oldName }) {
            for other in sites.indices where sites[other].proxyJump.contains(oldName) {
                sites[other].proxyJump = sites[other].proxyJump.map { $0 == oldName ? site.name : $0 }
            }
        }
        persist()
    }

    @ObservationIgnored private var erasedNames: [SavedSite.ID: String] = [:]

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

/// A key file offered for the Keychain when importing from ~/.ssh.
struct KeyImportCandidate: Identifiable {
    var id: String { path }
    /// Expanded, e.g. `/Users/me/.ssh/id_ed25519`.
    let path: String
    /// Nil when the file cannot be read (or is no key).
    let summary: SSHKeyFileSummary?
    /// Saved sites and not-yet-saved hosts that log in with it.
    let users: [String]
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

/// The Google Cloud OAuth client a TestFlight build carries (Config/appstore.env),
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
