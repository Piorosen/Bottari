import Foundation

/// The user's home folder. In the App Sandbox NSHomeDirectory() and "~" mean
/// the app's container instead, which holds none of the user's files.
public enum UserHome {
    public static let path: String = {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }()

    /// `~` and `~/…` against the real home; anything else as it is.
    public static func expand(_ path: String) -> String {
        if path == "~" { return Self.path }
        if path.hasPrefix("~/") { return Self.path + path.dropFirst() }
        return path
    }

    /// The other way round, for showing a path: `~/…` for anything in the home folder.
    public static func abbreviate(_ path: String) -> String {
        if path == Self.path { return "~" }
        if path.hasPrefix(Self.path + "/") { return "~" + path.dropFirst(Self.path.count) }
        return path
    }
}
