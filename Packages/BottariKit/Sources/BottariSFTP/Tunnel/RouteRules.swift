import Foundation

/// Which addresses go through a tunnel: IP ranges (CIDR), single addresses,
/// host names and `*.domain` wildcards, one per line.
public struct RouteRules: Equatable, Sendable {
    public enum Rule: Equatable, Sendable {
        case ipv4Range(address: UInt32, prefix: Int)
        case ipv6Range(address: [UInt8], prefix: Int)
        case host(String)
        /// `*.corp.example` matches every name below corp.example.
        case domain(String)
        /// `0.0.0.0/0`: everything.
        case everything
    }

    public let rules: [Rule]

    public init(rules: [Rule]) {
        self.rules = rules
    }

    /// Parses `text`; lines that are not rules are returned as `invalid`.
    public static func parse(_ text: String) -> (rules: RouteRules, invalid: [String]) {
        var rules: [Rule] = []
        var invalid: [String] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let rule = Rule(line) {
                rules.append(rule)
            } else {
                invalid.append(line)
            }
        }
        return (RouteRules(rules: rules), invalid)
    }

    /// Whether `host` (a name or a literal address) goes through the tunnel.
    public func matches(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let v4 = IPv4.parse(host)
        let v6 = v4 == nil ? IPv6.parse(host) : nil
        return rules.contains { rule in
            switch rule {
            case .everything:
                return true
            case .ipv4Range(let address, let prefix):
                guard let v4 else { return false }
                return IPv4.mask(v4, prefix) == IPv4.mask(address, prefix)
            case .ipv6Range(let address, let prefix):
                guard let v6 else { return false }
                return IPv6.mask(v6, prefix) == IPv6.mask(address, prefix)
            case .host(let name):
                return host == name
            case .domain(let suffix):
                return host == suffix || host.hasSuffix("." + suffix)
            }
        }
    }

    /// The networks for sshuttle, which routes IP ranges only.
    public var subnets: [String] {
        rules.compactMap { rule in
            switch rule {
            case .everything: "0/0"
            case .ipv4Range(let address, let prefix): "\(IPv4.format(address))/\(prefix)"
            case .ipv6Range(let address, let prefix): "\(IPv6.format(address))/\(prefix)"
            case .host(let name): name
            case .domain: nil
            }
        }
    }

    /// A proxy auto-configuration file: matching hosts use the SOCKS proxy (and
    /// the HTTP one for apps without SOCKS), everything else goes direct.
    public func pacFile(socksPort: Int, httpPort: Int?, fallBackToDirect: Bool) -> String {
        var proxies = ["SOCKS5 127.0.0.1:\(socksPort)", "SOCKS 127.0.0.1:\(socksPort)"]
        if let httpPort { proxies.append("PROXY 127.0.0.1:\(httpPort)") }
        if fallBackToDirect { proxies.append("DIRECT") }
        let tunnel = proxies.joined(separator: "; ")
        var tests: [String] = []
        for rule in rules {
            switch rule {
            case .everything:
                tests.append("true")
            case .host(let name):
                tests.append("host == \"\(name)\"")
            case .domain(let suffix):
                tests.append("host == \"\(suffix)\" || dnsDomainIs(host, \".\(suffix)\")")
            case .ipv4Range(let address, let prefix):
                // Only literal addresses: resolving names here would ask the local DNS,
                // which may not know internal hosts at all.
                tests.append("(isIPv4 && isInNet(host, \"\(IPv4.format(address))\", \"\(IPv4.format(IPv4.netmask(prefix)))\"))")
            case .ipv6Range:
                continue
            }
        }
        return """
        // Bottari tunnel: only these addresses go through the SSH server.
        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          var isIPv4 = /^\\d+\\.\\d+\\.\\d+\\.\\d+$/.test(host);
          if (\(tests.isEmpty ? "false" : tests.joined(separator: " ||\n      "))) {
            return "\(tunnel)";
          }
          return "DIRECT";
        }

        """
    }
}

extension RouteRules.Rule {
    init?(_ text: String) {
        let lower = text.lowercased()
        if lower == "0/0" || lower == "0.0.0.0/0" || lower == "::/0" {
            self = .everything
            return
        }
        let parts = lower.split(separator: "/", maxSplits: 1).map(String.init)
        let prefix = parts.count == 2 ? Int(parts[1]) : nil
        if parts.count == 2, prefix == nil { return nil }
        if let v4 = IPv4.parse(parts[0]) {
            let bits = prefix ?? 32
            guard (0...32).contains(bits) else { return nil }
            self = .ipv4Range(address: v4, prefix: bits)
        } else if let v6 = IPv6.parse(parts[0]) {
            let bits = prefix ?? 128
            guard (0...128).contains(bits) else { return nil }
            self = .ipv6Range(address: v6, prefix: bits)
        } else if parts.count == 1, lower.hasPrefix("*."), Self.isHostName(String(lower.dropFirst(2))) {
            self = .domain(String(lower.dropFirst(2)))
        } else if parts.count == 1, Self.isHostName(lower) {
            self = .host(lower)
        } else {
            return nil
        }
    }

    /// A DNS name. A last label of digits only is a mistyped address, not a name.
    private static func isHostName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 253 && !(text.split(separator: ".").last?.allSatisfy(\.isNumber) ?? true) && text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                && label.first != "-" && label.last != "-"
        }
    }
}

enum IPv4 {
    static func parse(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part), String(octet) == part else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }

    static func netmask(_ prefix: Int) -> UInt32 {
        prefix == 0 ? 0 : UInt32.max << (32 - prefix)
    }

    static func mask(_ address: UInt32, _ prefix: Int) -> UInt32 {
        address & netmask(prefix)
    }

    static func format(_ address: UInt32) -> String {
        (0..<4).map { String(address >> (24 - 8 * $0) & 0xFF) }.joined(separator: ".")
    }
}

enum IPv6 {
    static func parse(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard text.contains(":"), inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func mask(_ address: [UInt8], _ prefix: Int) -> [UInt8] {
        address.enumerated().map { index, byte in
            let bits = min(max(prefix - index * 8, 0), 8)
            return bits == 0 ? 0 : byte & UInt8(0xFF << (8 - bits) & 0xFF)
        }
    }

    static func format(_ address: [UInt8]) -> String {
        var raw = in6_addr()
        withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: address) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count))
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
