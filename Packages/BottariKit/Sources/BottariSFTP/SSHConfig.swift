import BottariCore
import Foundation

/// Reads OpenSSH client configuration (`~/.ssh/config`) the way `ssh` does for
/// the settings Bottari uses: Host blocks with wildcards and negation, Match
/// blocks, Include, and "first value wins" (IdentityFile accumulates).
///
/// Match conditions are checked the way `ssh` would for `all`, `host`,
/// `originalhost`, `user`, `localuser`, `localnetwork` and `final`. A block
/// with any other condition, `exec` included, does not apply: Bottari does
/// not run commands from the configuration to decide.
public struct SSHConfig: Sendable {
    /// Effective settings for one host name.
    public struct Host: Equatable, Sendable {
        /// The name typed after `ssh`, e.g. `prod-web`.
        public var alias: String
        /// Where to actually connect; the alias itself when there is no HostName.
        public var hostName: String
        public var user: String?
        public var port: Int
        /// Private key paths, with `~` and `%` tokens expanded, in the order to try.
        public var identityFiles: [String]
        /// Jump hosts to go through, first hop first, as written (`alias` or `user@host:port`).
        public var proxyJump: [String]
        /// A command whose standard input and output carry the connection, as
        /// written. Bottari runs none, but reads `ssh -W %h:%p jump` as a jump host.
        public var proxyCommand: String?

        public init(
            alias: String,
            hostName: String,
            user: String? = nil,
            port: Int = 22,
            identityFiles: [String] = [],
            proxyJump: [String] = [],
            proxyCommand: String? = nil
        ) {
            self.alias = alias
            self.hostName = hostName
            self.user = user
            self.port = port
            self.identityFiles = identityFiles
            self.proxyJump = proxyJump
            self.proxyCommand = proxyCommand
        }
    }

    private struct Block: Sendable {
        enum Condition: Sendable {
            /// `Host` patterns, matched against the name as typed.
            case host([String])
            /// `Match` criteria, all of which must hold.
            case match([Criterion])
        }

        var condition: Condition
        var options: [(key: String, value: String)]
        /// Conditions of the blocks an `Include` sat in, which must hold too.
        var enclosing: [Condition] = []
    }

    /// One condition on a `Match` line.
    struct Criterion: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case all, final, host, originalHost, user, localUser, localNetwork
            /// `exec`, `canonical`, `tagged` and anything newer: never true here.
            case unsupported
        }

        var kind: Kind
        var patterns: [String] = []
        var negated = false
    }

    private var blocks: [Block]
    private let home: String
    private let localUser: String
    private let localAddresses: @Sendable () -> [String]

    /// Every alias named on a Host line without wildcards, in file order.
    public let aliases: [String]

    /// The folder the configuration lives in, normally `~/.ssh`; also where
    /// the default key files are.
    public let directory: String

    /// Parses `text`. Relative Include paths resolve against `directory`
    /// (normally `~/.ssh`); `readFile` loads included files.
    public init(
        text: String,
        directory: String,
        home: String = UserHome.path,
        localUser: String = NSUserName(),
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        localAddresses: @escaping @Sendable () -> [String] = SSHConfig.interfaceAddresses
    ) {
        self.directory = directory
        self.home = home
        self.localUser = localUser
        self.localAddresses = localAddresses
        var blocks = [Block(condition: .host(["*"]), options: [])]
        Self.parse(text, directory: directory, home: home, readFile: readFile, depth: 0, enclosing: [], into: &blocks)
        self.blocks = blocks
        var seen = Set<String>()
        aliases = blocks.flatMap { block -> [String] in
            guard case .host(let patterns) = block.condition else { return [] }
            return patterns
        }.filter { pattern in
            !pattern.contains(where: { "*?!".contains($0) }) && seen.insert(pattern).inserted
        }
    }

    /// Loads `~/.ssh/config`, or an empty configuration if there is none.
    public static func load(home: String = UserHome.path) -> SSHConfig {
        let directory = (home as NSString).appendingPathComponent(".ssh")
        let text = (try? String(contentsOfFile: (directory as NSString).appendingPathComponent("config"), encoding: .utf8)) ?? ""
        return SSHConfig(text: text, directory: directory, home: home)
    }

    /// Concrete hosts (no wildcards) with their effective settings.
    public var hosts: [Host] {
        aliases.map(resolve)
    }

    /// The effective settings `ssh <alias>` would use.
    public func resolve(_ alias: String) -> Host {
        var values: [String: String] = [:]
        var identityFiles: [String] = []
        // Lazily: most configurations have no localnetwork condition.
        var addresses: [String]?
        func holds(_ condition: Block.Condition) -> Bool {
            switch condition {
            case .host(let patterns):
                return Self.matches(alias, patterns: patterns)
            case .match(let criteria):
                let hostName = values["hostname"].map { $0.replacingOccurrences(of: "%h", with: alias) } ?? alias
                return criteria.allSatisfy { criterion in
                    let result: Bool = switch criterion.kind {
                    case .all, .final: true
                    case .host: Self.matches(hostName, patterns: criterion.patterns)
                    case .originalHost: Self.matches(alias, patterns: criterion.patterns)
                    case .user: Self.matches(values["user"] ?? localUser, patterns: criterion.patterns)
                    case .localUser: Self.matches(localUser, patterns: criterion.patterns)
                    case .localNetwork:
                        Self.anyAddress(addresses ?? { addresses = localAddresses(); return addresses! }(), isIn: criterion.patterns)
                    case .unsupported: false
                    }
                    // An unsupported condition fails even when negated.
                    return criterion.kind == .unsupported ? false : result != criterion.negated
                }
            }
        }
        for block in blocks {
            guard holds(block.condition), block.enclosing.allSatisfy(holds) else { continue }
            for (key, value) in block.options {
                if key == "identityfile" {
                    identityFiles.append(value)
                } else if key == "proxyjump" || key == "proxycommand" {
                    // Whichever of the two comes first wins, and rules out the other.
                    if values["proxyjump"] == nil, values["proxycommand"] == nil {
                        values[key] = value
                    }
                } else if values[key] == nil {
                    values[key] = value
                }
            }
        }
        let hostName = values["hostname"].map { $0.replacingOccurrences(of: "%h", with: alias) } ?? alias
        let user = values["user"]
        let expand = { (path: String) in
            self.expand(path, alias: alias, hostName: hostName, remoteUser: user ?? self.localUser)
        }
        let jumps = values["proxyjump"].map { value in
            value.lowercased() == "none" ? [] : value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } ?? []
        return Host(
            alias: alias,
            hostName: hostName,
            user: user,
            port: values["port"].flatMap(Int.init) ?? 22,
            identityFiles: identityFiles.map(expand),
            proxyJump: jumps,
            proxyCommand: values["proxycommand"].flatMap { $0.lowercased() == "none" ? nil : $0 }
        )
    }

    // MARK: - Parsing

    private static func parse(
        _ text: String,
        directory: String,
        home: String,
        readFile: (String) -> String?,
        depth: Int,
        enclosing: [Block.Condition],
        into blocks: inout [Block]
    ) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let words = Self.words(in: rawLine)
            guard let keyword = words.first?.lowercased() else { continue }
            let arguments = Array(words.dropFirst())
            switch keyword {
            case "host":
                blocks.append(Block(condition: .host(arguments), options: [], enclosing: enclosing))
            case "match":
                blocks.append(Block(condition: .match(Self.criteria(arguments)), options: [], enclosing: enclosing))
            case "include":
                guard depth < 8 else { continue }
                // As in ssh, an Include inside a Host or Match block counts only
                // where that block applies, and the lines after it go back to
                // that block rather than to the included file's last one.
                let around = blocks[blocks.count - 1]
                let before = blocks.count
                for pattern in arguments {
                    for path in Self.includedFiles(pattern, directory: directory, home: home) {
                        guard let included = readFile(path) else { continue }
                        parse(included, directory: directory, home: home, readFile: readFile, depth: depth + 1, enclosing: around.enclosing + [around.condition], into: &blocks)
                    }
                }
                if blocks.count != before {
                    blocks.append(Block(condition: around.condition, options: [], enclosing: around.enclosing))
                }
            case "proxycommand":
                // The command is the rest of the line, as written.
                guard let command = Self.rest(of: rawLine) else { continue }
                blocks[blocks.count - 1].options.append((keyword, command))
            default:
                guard let first = arguments.first else { continue }
                // Everything else Bottari reads takes one argument; for ProxyJump also
                // accept "a, b", which ssh rejects but people write.
                let value = keyword == "proxyjump" ? arguments.joined(separator: " ") : first
                blocks[blocks.count - 1].options.append((keyword, value))
            }
        }
    }

    /// The words after `Match`, as criteria. Most take a comma-separated
    /// pattern list; `all`, `final` and `canonical` take nothing.
    static func criteria(_ words: [String]) -> [Criterion] {
        var criteria: [Criterion] = []
        var index = words.startIndex
        while index < words.endIndex {
            var name = words[index].lowercased()
            index += 1
            let negated = name.hasPrefix("!")
            if negated { name.removeFirst() }
            let kind: Criterion.Kind
            switch name {
            case "all": kind = .all
            case "final": kind = .final
            case "canonical":
                criteria.append(Criterion(kind: .unsupported, negated: negated))
                continue
            case "host": kind = .host
            case "originalhost": kind = .originalHost
            case "user": kind = .user
            case "localuser": kind = .localUser
            case "localnetwork": kind = .localNetwork
            default: kind = .unsupported
            }
            if kind == .all || kind == .final {
                criteria.append(Criterion(kind: kind, negated: negated))
                continue
            }
            let patterns = index < words.endIndex ? words[index].split(separator: ",").map(String.init) : []
            index += 1
            criteria.append(Criterion(kind: kind, patterns: patterns, negated: negated))
        }
        return criteria.isEmpty ? [Criterion(kind: .unsupported)] : criteria
    }

    /// What follows the keyword on a line, as written apart from the
    /// separating whitespace or `=`.
    static func rest(of line: Substring) -> String? {
        var rest = line.drop(while: \.isWhitespace).drop { !$0.isWhitespace && $0 != "=" }
        rest = rest.drop(while: \.isWhitespace)
        if rest.first == "=" { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Splits a config line into words: `Key value`, `Key=value`,
    /// `Key = value`, quotes, `#` comments. One `=` between the keyword and
    /// its value is a separator; any other `=` is part of a value.
    static func words(in line: Substring) -> [String] {
        let start = line.drop(while: \.isWhitespace)
        let keyword = start.prefix { !$0.isWhitespace && $0 != "=" && $0 != "#" }
        guard !keyword.isEmpty else { return [] }
        var rest = start.dropFirst(keyword.count).drop(while: \.isWhitespace)
        if rest.first == "=" { rest = rest.dropFirst() }
        var words = [String(keyword)]
        var current = ""
        var inQuotes = false
        for character in rest {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes {
                if character == "#" { break }
                if character.isWhitespace {
                    if !current.isEmpty {
                        words.append(current)
                        current = ""
                    }
                    continue
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func includedFiles(_ pattern: String, directory: String, home: String) -> [String] {
        var path = pattern
        if path.hasPrefix("~") { path = home + path.dropFirst() }
        if !path.hasPrefix("/") { path = (directory as NSString).appendingPathComponent(path) }
        guard path.contains(where: { "*?[".contains($0) }) else { return [path] }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(path, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }.sorted()
    }

    /// Whether any of `addresses` falls in one of the `10.0.0.0/8` or
    /// `fd00::/8` style ranges; `!range` excludes, as in `localnetwork`.
    static func anyAddress(_ addresses: [String], isIn ranges: [String]) -> Bool {
        addresses.contains { address in
            var matched = false
            for range in ranges {
                let negated = range.hasPrefix("!")
                guard let network = IPRange(negated ? String(range.dropFirst()) : range), network.contains(address) else { continue }
                if negated { return false }
                matched = true
            }
            return matched
        }
    }

    /// This Mac's interface addresses, IPv4 and IPv6.
    public static let interfaceAddresses: @Sendable () -> [String] = {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            // Drop an IPv6 zone such as `%en0`.
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            addresses.append(String(text.split(separator: "%")[0]))
        }
        return addresses
    }

    static func matches(_ name: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if fnmatch(String(pattern.dropFirst()), name, 0) == 0 { return false }
            } else if fnmatch(pattern, name, 0) == 0 {
                matched = true
            }
        }
        return matched
    }

    private func expand(_ path: String, alias: String, hostName: String, remoteUser: String) -> String {
        var out = ""
        var iterator = path.makeIterator()
        while let character = iterator.next() {
            guard character == "%", let token = iterator.next() else {
                out.append(character)
                continue
            }
            switch token {
            case "d": out += home
            case "h": out += hostName
            case "n": out += alias
            case "r": out += remoteUser
            case "u": out += localUser
            case "%": out += "%"
            default: out += "%\(token)"
            }
        }
        if out.hasPrefix("~") { out = home + out.dropFirst() }
        return out
    }
}

/// An address range written as `address/prefix length`.
struct IPRange {
    private let network: [UInt8]
    private let prefix: Int

    init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1)
        guard let address = IPRange.bytes(String(parts[0])) else { return nil }
        let prefix = parts.count == 2 ? Int(parts[1]) : address.count * 8
        guard let prefix, (0...address.count * 8).contains(prefix) else { return nil }
        network = address
        self.prefix = prefix
    }

    func contains(_ text: String) -> Bool {
        guard let address = IPRange.bytes(text), address.count == network.count else { return false }
        var remaining = prefix
        for (a, b) in zip(address, network) where remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if a & mask != b & mask { return false }
            remaining -= bits
        }
        return true
    }

    private static func bytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }
}
