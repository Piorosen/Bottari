import Foundation

/// A server the user saved. Secrets are not part of it; they live in a `SecretStore`.
public struct SavedSite: Identifiable, Codable, Hashable, Sendable {
    public enum Authentication: Codable, Hashable, Sendable {
        /// Keys held by an SSH agent; `socket` nil means `SSH_AUTH_SOCK`.
        case agent(socket: String?)
        /// An OpenSSH private key file. Its passphrase, if any, is in the secret store.
        case keyFile(path: String)
        /// A password kept in the secret store.
        case password
    }

    /// The colour tag from the design: PROD gets a warning band and confirmations.
    public enum Tag: String, Codable, CaseIterable, Sendable {
        case prod, staging, dev, personal
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
        confirmsWrites: Bool? = nil
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
    }

    /// A site for an `~/.ssh/config` host: its IdentityAgent if set, otherwise its
    /// first IdentityFile that exists, otherwise the default agent, like `ssh`.
    public init(importing host: SSHConfig.Host, defaultUser: String, fileExists: (String) -> Bool) {
        let authentication: Authentication
        if let agent = host.identityAgent, agent != "none" {
            authentication = .agent(socket: agent)
        } else if let key = host.identityFiles.first(where: fileExists) {
            authentication = .keyFile(path: key)
        } else {
            authentication = .agent(socket: nil)
        }
        self.init(
            name: host.alias,
            endpoint: SFTPEndpoint(host: host.hostName, port: host.port, username: host.user ?? defaultUser),
            authentication: authentication,
            proxyJump: host.proxyJump,
            sshConfigAlias: host.alias
        )
    }

    public var passwordKey: String { "site.\(id.uuidString).password" }
    public var passphraseKey: String { "site.\(id.uuidString).passphrase" }
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
}

/// Why a saved site could not be turned into a connection plan.
public enum SiteConnectError: Error, Equatable, Sendable {
    /// No password was given and none is stored for this site.
    case passwordMissing(site: String)
    case keyFileUnreadable(path: String)
    /// Jump hosts refer back to each other.
    case jumpLoop(String)
}

extension SiteConnectError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passwordMissing(let site): "\(site)의 비밀번호가 저장되어 있지 않아요."
        case .keyFileUnreadable(let path): "키 파일을 읽지 못했어요: \(path)"
        case .jumpLoop(let name): "점프 호스트가 서로를 가리키고 있어요: \(name)"
        }
    }
}

extension SavedSite {
    public typealias FileReader = @Sendable (String) -> String?

    public static let readFile: FileReader = { try? String(contentsOfFile: $0, encoding: .utf8) }

    /// The site's credential, with secrets taken from `secrets`. A `password`
    /// passed in (just typed by the user) wins over a stored one.
    public func credential(secrets: SecretStore, password: String? = nil, readFile: FileReader = SavedSite.readFile) throws -> SFTPCredential {
        switch authentication {
        case .agent(let socket):
            return .agent(socket: socket)
        case .keyFile(let path):
            guard let text = readFile((path as NSString).expandingTildeInPath) else {
                throw SiteConnectError.keyFileUnreadable(path: path)
            }
            return .privateKey(text, passphrase: try secrets.secret(for: passphraseKey))
        case .password:
            guard let password = try password ?? secrets.secret(for: passwordKey) else {
                throw SiteConnectError.passwordMissing(site: name)
            }
            return .password(password)
        }
    }

    /// The endpoint, credential and jump hosts to connect to this site. Each
    /// ProxyJump name is looked up among `sites`, then in `sshConfig`, and is
    /// otherwise read as `[user@]host[:port]` and tried with the default agent.
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
            credential: try credential(secrets: secrets, password: password, readFile: readFile),
            hops: try resolver.hops(for: proxyJump, visiting: [name])
        )
    }

    /// `[user@]host[:port]`, as ProxyJump writes a hop.
    static func endpoint(parsingHop text: String, defaultUser: String) -> SFTPEndpoint {
        var rest = Substring(text)
        var user = defaultUser
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var port = 22
        if let colon = rest.lastIndex(of: ":"), let parsed = Int(rest[rest.index(after: colon)...]) {
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
                hops.append(SSHHop(endpoint: site.endpoint, credential: try site.credential(secrets: secrets, readFile: readFile)))
            } else {
                hops.append(SSHHop(endpoint: SavedSite.endpoint(parsingHop: name, defaultUser: defaultUser), credential: .agent()))
            }
        }
        return hops
    }
}
