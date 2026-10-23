import Foundation

/// One entry in a directory listing, from any provider.
public struct FileItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case file
        case directory
        case other
    }

    public var id: RemotePath { path }

    public let path: RemotePath
    public let kind: Kind
    /// True when the entry is a symbolic link; `kind` describes what it points at.
    public let isSymbolicLink: Bool
    public let size: Int64?
    public let modified: Date?
    /// POSIX mode bits, e.g. `0o755`. Nil when the provider has no such concept.
    public let permissions: UInt16?
    public let owner: String?
    /// For files in iCloud Drive: whether the bytes are on this Mac.
    public let cloud: CloudState?

    public enum CloudState: Hashable, Sendable {
        case downloaded
        /// Only in iCloud; opening it downloads it.
        case inCloud
        case downloading
    }

    public init(
        path: RemotePath,
        kind: Kind,
        isSymbolicLink: Bool = false,
        size: Int64? = nil,
        modified: Date? = nil,
        permissions: UInt16? = nil,
        owner: String? = nil,
        cloud: CloudState? = nil
    ) {
        self.path = path
        self.kind = kind
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.cloud = cloud
    }

    public var name: String { path.name }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }

    /// `ls -l` style mode string, e.g. `drwxr-xr-x`.
    public var permissionString: String? {
        guard let permissions else { return nil }
        let type: Character = isSymbolicLink ? "l" : (isDirectory ? "d" : "-")
        let flags: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String([type] + flags.map { permissions & $0.0 != 0 ? $0.1 : "-" })
    }

    /// Finder order: directories first, then names compared the way Finder does
    /// (`file2` before `file10`, case-insensitive).
    public static func finderOrder(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
