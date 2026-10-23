/// An absolute, normalized POSIX-style path on any provider, e.g. `/var/www/site`.
///
/// Every provider speaks in these paths so panes can treat the Mac, an SFTP server
/// and a cloud drive the same way. Providers that are not path-based map their own
/// identifiers onto this shape.
public struct RemotePath: Hashable, Sendable {
    public let components: [String]

    public static let root = RemotePath(normalized: [])

    /// Parses `string`, collapsing duplicate slashes, `.` and `..`.
    /// Relative input is treated as relative to the root.
    public init(_ string: String) {
        var out: [String] = []
        for part in string.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if !out.isEmpty { out.removeLast() }
            default:
                out.append(String(part))
            }
        }
        self.init(normalized: out)
    }

    private init(normalized components: [String]) {
        self.components = components
    }

    public var string: String { "/" + components.joined(separator: "/") }

    /// The last component, or `/` for the root.
    public var name: String { components.last ?? "/" }

    public var isRoot: Bool { components.isEmpty }

    public var parent: RemotePath? {
        isRoot ? nil : RemotePath(normalized: Array(components.dropLast()))
    }

    /// The extension of the last component without the dot, or an empty string.
    public var pathExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// Every path from the root down to this one, for breadcrumbs.
    public var lineage: [RemotePath] {
        (0...components.count).map { RemotePath(normalized: Array(components.prefix($0))) }
    }

    /// Appends a relative path, which may itself contain `/`, `.` or `..`.
    public func appending(_ relative: String) -> RemotePath {
        RemotePath(string + "/" + relative)
    }

    /// Where an unfinished write to this path keeps its bytes until it is swapped into place.
    public var partialWritePath: RemotePath {
        (parent ?? .root).appending(".\(name).bottari-part")
    }

    public func isAncestor(of other: RemotePath) -> Bool {
        other.components.count > components.count && other.components.starts(with: components)
    }
}

extension RemotePath: CustomStringConvertible {
    public var description: String { string }
}

extension RemotePath: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension RemotePath: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
