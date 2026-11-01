import BottariCore
import Foundation

/// A server the user saved. Secrets are not part of it; they live in a `SecretStore`.
public struct SavedSite: Identifiable, Codable, Hashable, Sendable {
    public enum Authentication: Codable, Hashable, Sendable {
        /// The key files `ssh` tries when a host names none: `~/.ssh/id_ed25519`,
        /// `id_ecdsa` and `id_rsa`.
        case defaultKeys
        /// An OpenSSH private key file. Its passphrase, if any, is in the secret store.
        case keyFile(path: String)
        /// A key Bottari made for the site and keeps in the secret store, one
        /// per Mac: the site syncs, the key stays where it was made.
        case storedKey
        /// A password kept in the secret store.
        case password

        /// Saved as `agent`, its name from when Bottari asked an SSH agent
        /// first, so sites.json reads the same in older and newer copies.
        private enum CodingKeys: String, CodingKey {
            case defaultKeys = "agent"
            case keyFile, storedKey, password
        }
    }

    /// The colour tag from the design: PROD gets a warning band and confirmations.
    public enum Tag: String, Codable, CaseIterable, Sendable {
        case prod, staging, dev, personal
    }

    /// What kind of place this is. Cloud sites keep only their own settings;
    /// the SFTP fields are unused for them.
    public enum Kind: Codable, Hashable, Sendable {
        case sftp
        case s3(S3Settings)
        case googleDrive(DriveSettings)
    }

    public struct S3Settings: Codable, Hashable, Sendable {
        public var bucket = ""
        public var region = "us-east-1"
        /// Empty for AWS; the address of R2, MinIO and the like otherwise.
        public var endpoint = ""
        public var accessKey = ""
        public var usesPathStyle = false

        public init() {}
    }

    public struct DriveSettings: Codable, Hashable, Sendable {
        /// The user's own Google Cloud OAuth client (desktop app).
        public var clientID = ""
        /// "office", "pdf" or "openDocument": how Google Docs come down.
        public var exportFormat = "office"
        /// The signed-in account's email; empty until signed in.
        public var account = ""

        public init() {}
    }

    /// A remote screen on the same machine.
    public struct RemoteScreen: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            /// A VNC server such as TigerVNC or x11vnc.
            case vnc
            /// macOS Screen Sharing, which signs in with a macOS account.
            case appleScreenSharing
        }

        public var kind: Kind
        public var port: Int
        /// Over the site's SSH connection, so the screen port need not be open on
        /// the server's firewall and VNC's weak encryption never crosses the network.
        public var throughTunnel: Bool

        public init(kind: Kind, port: Int = 5900, throughTunnel: Bool = true) {
            self.kind = kind
            self.port = port
            self.throughTunnel = throughTunnel
        }
    }

    public var id: UUID
    public var name: String
    public var endpoint: SFTPEndpoint
    public var authentication: Authentication
    /// Jump hosts, first hop first: saved-site names, `~/.ssh/config` aliases or `user@host:port`.
    public var proxyJump: [String]
    public var tag: Tag?
    public var startPath: String?
    /// The `~/.ssh/config` alias this site was imported from, so importing again skips it.
    public var sshConfigAlias: String?
    /// Hide actions that change files on this server.
    public var readOnly: Bool
    /// Ask before copying onto, overwriting or deleting on this server. PROD sites start with it on.
    public var confirmsWrites: Bool
    public var remoteScreen: RemoteScreen?
    public var kind: Kind

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: SFTPEndpoint,
        authentication: Authentication,
        proxyJump: [String] = [],
        tag: Tag? = nil,
        startPath: String? = nil,
        sshConfigAlias: String? = nil,
        readOnly: Bool = false,
        confirmsWrites: Bool? = nil,
        remoteScreen: RemoteScreen? = nil,
        kind: Kind = .sftp
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.authentication = authentication
        self.proxyJump = proxyJump
        self.tag = tag
        self.startPath = startPath
        self.sshConfigAlias = sshConfigAlias
        self.readOnly = readOnly
        self.confirmsWrites = confirmsWrites ?? (tag == .prod)
        self.remoteScreen = remoteScreen
        self.kind = kind
    }

    /// Settings added later get their defaults when an older sites.json lacks them.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        endpoint = try values.decode(SFTPEndpoint.self, forKey: .endpoint)
        authentication = try values.decode(Authentication.self, forKey: .authentication)
        proxyJump = try values.decodeIfPresent([String].self, forKey: .proxyJump) ?? []
        tag = try values.decodeIfPresent(Tag.self, forKey: .tag)
        startPath = try values.decodeIfPresent(String.self, forKey: .startPath)
        sshConfigAlias = try values.decodeIfPresent(String.self, forKey: .sshConfigAlias)
        readOnly = try values.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        confirmsWrites = try values.decodeIfPresent(Bool.self, forKey: .confirmsWrites) ?? (tag == .prod)
        remoteScreen = try values.decodeIfPresent(RemoteScreen.self, forKey: .remoteScreen)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .sftp
    }

    public var isSFTP: Bool {
        if case .sftp = kind { true } else { false }
    }

    /// A site for an `~/.ssh/config` host: its first IdentityFile that exists,
    /// otherwise the default key files, like `ssh`. Bottari runs no commands,
    /// but a ProxyCommand that is `ssh -W %h:%p jump` only goes through a jump
    /// host, which Bottari does itself.
    public init(importing host: SSHConfig.Host, defaultUser: String, fileExists: (String) -> Bool) {
        var proxyJump = host.proxyJump
        if proxyJump.isEmpty, let command = host.proxyCommand, let jump = Self.jumpHost(inProxyCommand: command) {
            proxyJump = [jump]
        }
        self.init(
            name: host.alias,
            endpoint: SFTPEndpoint(host: host.hostName, port: host.port, username: host.user ?? defaultUser),
            authentication: host.identityFiles.first(where: fileExists).map { .keyFile(path: $0) } ?? .defaultKeys,
            proxyJump: proxyJump,
            sshConfigAlias: host.alias
        )
    }

    /// The host of a ProxyCommand that is nothing but `ssh -W %h:%p host`
    /// (with -q, -T or -x at most), the old way of writing ProxyJump.
    static func jumpHost(inProxyCommand command: String) -> String? {
        var words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first, program == "ssh" || program.hasSuffix("/ssh") else { return nil }
        words.removeFirst()
        guard let relay = words.firstIndex(of: "-W"), words.indices.contains(relay + 1), words[relay + 1] == "%h:%p" else { return nil }
        words.removeSubrange(relay...relay + 1)
        words.removeAll { ["-q", "-T", "-x"].contains($0) }
        guard words.count == 1, let host = words.first, !host.hasPrefix("-"), !host.contains("%") else { return nil }
        return host
    }

    /// Where to open the site: its start folder, with `~` meaning the login folder `home`.
    public func startLocation(home: RemotePath) -> RemotePath {
        guard let startPath = startPath?.trimmingCharacters(in: .whitespaces), !startPath.isEmpty, startPath != "~" else {
            return home
        }
        if startPath.hasPrefix("~/") {
            return home.appending(String(startPath.dropFirst(2)))
        }
        return startPath.hasPrefix("/") ? RemotePath(startPath) : home.appending(startPath)
    }

    public var passwordKey: String { "site.\(id.uuidString).password" }
    public var passphraseKey: String { "site.\(id.uuidString).passphrase" }
    /// The key Bottari made for the site, in OpenSSH's format.
    public var privateKeyKey: String { "site.\(id.uuidString).key" }
    /// The VNC or Screen Sharing password.
    public var screenPasswordKey: String { "site.\(id.uuidString).screen" }
    /// The account a Screen Sharing password belongs to, kept beside it.
    public var screenUsernameKey: String { "site.\(id.uuidString).screen-user" }
    public var s3SecretKey: String { "site.\(id.uuidString).s3secret" }
    /// The archived Google sign-in, base64.
    public var googleSignInKey: String { "site.\(id.uuidString).google" }
    public var googleClientSecretKey: String { "site.\(id.uuidString).googleClientSecret" }
}

/// Saved sites as a JSON file.
public struct SiteStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The saved sites, or none if nothing was saved yet.
    public func load() throws -> [SavedSite] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([SavedSite].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ sites: [SavedSite]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(sites).write(to: fileURL, options: .atomic)
    }

    /// Adds every `~/.ssh/config` host that is not saved yet. Sites imported
    /// before are left alone, so the user's edits survive a second import.
    public static func importing(
        _ config: SSHConfig,
        into sites: [SavedSite],
        defaultUser: String = NSUserName(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (sites: [SavedSite], added: [SavedSite]) {
        let known = Set(sites.compactMap(\.sshConfigAlias))
        let added = config.hosts
            .filter { !known.contains($0.alias) }
            .map { SavedSite(importing: $0, defaultUser: defaultUser, fileExists: fileExists) }
        return (sites + added, added)
    }
}

/// Everything `SFTPFileProvider.connect` needs for a saved site.
public struct ConnectionPlan: Equatable, Sendable {
    public var endpoint: SFTPEndpoint
    public var credential: SFTPCredential
    public var hops: [SSHHop]

    init(endpoint: SFTPEndpoint, credential: SFTPCredential, hops: [SSHHop]) {
        self.endpoint = endpoint
        self.credential = credential
        self.hops = hops
    }

    /// This plan reached through `via`'s server, which becomes the first hop.
    public func through(_ via: ConnectionPlan) -> ConnectionPlan {
        ConnectionPlan(
            endpoint: endpoint,
            credential: credential,
            hops: via.hops + [SSHHop(endpoint: via.endpoint, credential: via.credential)] + hops
        )
    }
}

/// Why a saved site could not be turned into a connection plan.
public enum SiteConnectError: Error, Equatable, Sendable {
    /// No password was given and none is stored for the site named `site`
    /// (the one connected to, or a jump host on the way). `key` is where its
    /// password goes in the secret store, so it can be asked for and kept.
    case passwordMissing(site: String, key: String)
    /// A password is saved for the site, but the Keychain would not hand it
    /// to this app; typing it again replaces the saved one.
    case passwordUnreadable(site: String, key: String)
    /// The site's key file cannot be read (outside the folders the App
    /// Sandbox lets Bottari into, or gone) and no password is saved for it;
    /// `key` is where one would go.
    case keyFileUnreadable(path: String, site: String, key: String)
    /// The site logs in with a key Bottari made on another Mac, and none is
    /// kept on this one; `key` is where a password would go.
    case storedKeyMissing(site: String, key: String)
    /// Jump hosts refer back to each other.
    case jumpLoop(String)
}

extension SiteConnectError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passwordMissing(let site, _): String(localized: "\(site)의 비밀번호가 저장되어 있지 않습니다.")
        case .passwordUnreadable(let site, _): String(localized: "키체인에 저장된 \(site)의 비밀번호를 읽을 수 없습니다. 다시 입력하면 새로 저장합니다.")
        case .keyFileUnreadable(let path, _, _): String(localized: "키 파일을 읽을 수 없습니다: \(path)")
        case .storedKeyMissing(let site, _): String(localized: "이 Mac에는 \(site)의 Bottari 키가 없습니다. 비밀번호로 로그인하면 이 Mac의 키를 만들어 설치할 수 있습니다.")
        case .jumpLoop(let name): String(localized: "점프 호스트가 서로를 참조하고 있습니다: \(name)")
        }
    }
}

extension SavedSite {
    public typealias FileReader = @Sendable (String) -> String?

    public static let readFile: FileReader = { try? String(contentsOfFile: $0, encoding: .utf8) }

    /// The key files `ssh` falls back to when a host names none, limited to the
    /// kinds Bottari can read, Ed25519 first.
    public static let defaultKeyFiles = ["id_ed25519", "id_ecdsa", "id_rsa"]

    /// The default key files in `sshDirectory` that could be read (none when
    /// it is nil or empty).
    static func defaultKeysCredential(sshDirectory: String?, readFile: FileReader) -> SFTPCredential {
        guard let sshDirectory, !sshDirectory.isEmpty else { return .defaultKeys([]) }
        return .defaultKeys(defaultKeyFiles.compactMap { readFile((sshDirectory as NSString).appendingPathComponent($0)) })
    }

    /// The site's credential, with secrets taken from `secrets`. A `password`
    /// passed in (just typed by the user) wins over a stored one. Default keys
    /// are read from `sshDirectory`. A site that logs in with keys but also has
    /// a password tries the keys first, then the password, the way `ssh` does;
    /// with its key out of reach, the password alone.
    public func credential(secrets: SecretStore, password: String? = nil, sshDirectory: String? = nil, readFile: FileReader = SavedSite.readFile) throws -> SFTPCredential {
        let keys: SFTPCredential
        switch authentication {
        case .defaultKeys:
            keys = Self.defaultKeysCredential(sshDirectory: sshDirectory, readFile: readFile)
        case .keyFile(let path):
            guard let text = readFile(UserHome.expand(path)) else {
                if let password = try password ?? secrets.readableSecret(for: passwordKey) { return .password(password) }
                throw SiteConnectError.keyFileUnreadable(path: path, site: name, key: passwordKey)
            }
            // An unreadable passphrase is asked for again, like a missing one.
            keys = .privateKey(text, passphrase: try secrets.readableSecret(for: passphraseKey))
        case .storedKey:
            guard let text = try secrets.readableSecret(for: privateKeyKey) else {
                if let password = try password ?? secrets.readableSecret(for: passwordKey) { return .password(password) }
                throw SiteConnectError.storedKeyMissing(site: name, key: passwordKey)
            }
            keys = .privateKey(text, passphrase: nil)
        case .password:
            let stored: String?
            do {
                stored = try password ?? secrets.secret(for: passwordKey)
            } catch SecretStoreError.unreadable {
                throw SiteConnectError.passwordUnreadable(site: name, key: passwordKey)
            }
            guard let stored else {
                throw SiteConnectError.passwordMissing(site: name, key: passwordKey)
            }
            return .password(stored)
        }
        guard let password = try password ?? secrets.readableSecret(for: passwordKey) else { return keys }
        return .fallback(keys, then: .password(password))
    }

    /// The endpoint, credential and jump hosts to connect to this site. Each
    /// ProxyJump name is looked up among `sites`, then in `sshConfig`, and is
    /// otherwise read as `[user@]host[:port]` and tried with the default key files.
    public func connectionPlan(
        sites: [SavedSite],
        sshConfig: SSHConfig,
        secrets: SecretStore,
        password: String? = nil,
        defaultUser: String = NSUserName(),
        readFile: @escaping FileReader = SavedSite.readFile
    ) throws -> ConnectionPlan {
        let resolver = HopResolver(sites: sites, sshConfig: sshConfig, secrets: secrets, defaultUser: defaultUser, readFile: readFile)
        return ConnectionPlan(
            endpoint: endpoint,
            credential: try credential(secrets: secrets, password: password, sshDirectory: sshConfig.directory, readFile: readFile),
            hops: try resolver.hops(for: proxyJump, visiting: [name])
        )
    }

    /// `[user@]host[:port]`, as ProxyJump writes a hop. An IPv6 address
    /// comes bare (`2001:db8::1`, no port) or in brackets (`[2001:db8::1]:2222`).
    static func endpoint(parsingHop text: String, defaultUser: String) -> SFTPEndpoint {
        var rest = Substring(text)
        var user = defaultUser
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var port = 22
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":"), let parsed = Int(after.dropFirst()) { port = parsed }
            rest = rest[rest.index(after: rest.startIndex)..<close]
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.lastIndex(of: ":"), let parsed = Int(rest[rest.index(after: colon)...]) {
            // One colon is a port; more mean a bare IPv6 address.
            port = parsed
            rest = rest[..<colon]
        }
        return SFTPEndpoint(host: String(rest), port: port, username: user)
    }
}

private struct HopResolver {
    let sites: [SavedSite]
    let sshConfig: SSHConfig
    let secrets: SecretStore
    let defaultUser: String
    let readFile: SavedSite.FileReader

    func hops(for names: [String], visiting: Set<String>) throws -> [SSHHop] {
        var hops: [SSHHop] = []
        for name in names {
            guard !visiting.contains(name) else { throw SiteConnectError.jumpLoop(name) }
            let site: SavedSite? = sites.first { $0.name == name || $0.sshConfigAlias == name }
                ?? (sshConfig.aliases.contains(name)
                    ? SavedSite(importing: sshConfig.resolve(name), defaultUser: defaultUser, fileExists: { readFile($0) != nil })
                    : nil)
            if let site {
                // A jump host can have its own jump hosts; those come first.
                hops += try self.hops(for: site.proxyJump, visiting: visiting.union([name]))
                hops.append(SSHHop(
                    endpoint: site.endpoint,
                    credential: try site.credential(secrets: secrets, sshDirectory: sshConfig.directory, readFile: readFile)
                ))
            } else {
                let credential = SavedSite.defaultKeysCredential(sshDirectory: sshConfig.directory, readFile: readFile)
                hops.append(SSHHop(endpoint: SavedSite.endpoint(parsingHop: name, defaultUser: defaultUser), credential: credential))
            }
        }
        return hops
    }
}
