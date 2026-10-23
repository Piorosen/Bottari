import Foundation

/// Reads OpenSSH client configuration (`~/.ssh/config`) the way `ssh` does for
/// the settings Bottari uses: Host blocks with wildcards and negation, Include,
/// and "first value wins" (IdentityFile accumulates).
///
/// Match blocks are skipped: their conditions (exec, localnetwork …) need a
/// real `ssh` to evaluate.
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
        /// Agent socket from IdentityAgent, e.g. 1Password's; nil means `SSH_AUTH_SOCK`.
        public var identityAgent: String?
    }

    private struct Block: Sendable {
        var patterns: [String]
        var options: [(key: String, value: String)]
    }

    private var blocks: [Block]
    private let home: String
    private let localUser: String

    /// Every alias named on a Host line without wildcards, in file order.
    public let aliases: [String]

    /// Parses `text`. Relative Include paths resolve against `directory`
    /// (normally `~/.ssh`); `readFile` loads included files.
    public init(
        text: String,
        directory: String,
        home: String = NSHomeDirectory(),
        localUser: String = NSUserName(),
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) {
        self.home = home
        self.localUser = localUser
        var blocks = [Block(patterns: ["*"], options: [])]
        Self.parse(text, directory: directory, home: home, readFile: readFile, depth: 0, into: &blocks)
        self.blocks = blocks
        var seen = Set<String>()
        aliases = blocks.flatMap(\.patterns).filter { pattern in
            !pattern.contains(where: { "*?!".contains($0) }) && seen.insert(pattern).inserted
        }
    }

    /// Loads `~/.ssh/config`, or an empty configuration if there is none.
    public static func load(home: String = NSHomeDirectory()) -> SSHConfig {
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
        for block in blocks where Self.matches(alias, patterns: block.patterns) {
            for (key, value) in block.options {
                if key == "identityfile" {
                    identityFiles.append(value)
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
        let agent = values["identityagent"].flatMap { value -> String? in
            switch value {
            case "none": "none"
            case "SSH_AUTH_SOCK": nil
            default: expand(value.hasPrefix("$") ? (ProcessInfo.processInfo.environment[String(value.dropFirst())] ?? value) : value)
            }
        }
        return Host(
            alias: alias,
            hostName: hostName,
            user: user,
            port: values["port"].flatMap(Int.init) ?? 22,
            identityFiles: identityFiles.map(expand),
            proxyJump: jumps,
            identityAgent: agent
        )
    }

    // MARK: - Parsing

    private static func parse(
        _ text: String,
        directory: String,
        home: String,
        readFile: (String) -> String?,
        depth: Int,
        into blocks: inout [Block]
    ) {
        var skippingMatch = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let words = Self.words(in: rawLine)
            guard let keyword = words.first?.lowercased() else { continue }
            let arguments = Array(words.dropFirst())
            switch keyword {
            case "host":
                skippingMatch = false
                blocks.append(Block(patterns: arguments, options: []))
            case "match":
                skippingMatch = true
            case "include":
                guard !skippingMatch, depth < 8 else { continue }
                for pattern in arguments {
                    for path in Self.includedFiles(pattern, directory: directory, home: home) {
                        guard let included = readFile(path) else { continue }
                        parse(included, directory: directory, home: home, readFile: readFile, depth: depth + 1, into: &blocks)
                    }
                }
            default:
                guard !skippingMatch, let first = arguments.first else { continue }
                // Everything Bottari reads takes one argument; for ProxyJump also accept
                // "a, b", which ssh rejects but people write.
                let value = keyword == "proxyjump" ? arguments.joined(separator: " ") : first
                blocks[blocks.count - 1].options.append((keyword, value))
            }
        }
    }

    /// Splits a config line into words: `Key value`, `Key=value`, quotes, `#` comments.
    static func words(in line: Substring) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuotes = false
        var sawKeyword = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes {
                if character == "#" { break }
                // The first `=` separates the keyword from its value.
                if character.isWhitespace || (character == "=" && !sawKeyword) {
                    if !current.isEmpty {
                        words.append(current)
                        current = ""
                        sawKeyword = true
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
