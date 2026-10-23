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

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: SFTPEndpoint,
        authentication: Authentication,
        proxyJump: [String] = [],
        tag: Tag? = nil,
        startPath: String? = nil,
        sshConfigAlias: String? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.authentication = authentication
        self.proxyJump = proxyJump
        self.tag = tag
        self.startPath = startPath
        self.sshConfigAlias = sshConfigAlias
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
