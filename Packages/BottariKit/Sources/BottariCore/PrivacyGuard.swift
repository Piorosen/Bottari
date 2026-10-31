import Foundation

/// Folders macOS guards with a privacy prompt: the first time an app looks
/// inside one, the system stops and asks the user. Listing a folder that merely
/// contains one must not do that, so links into them are not followed and
/// their icons are not read until the user opens them.
public struct PrivacyGuard: Sendable {
    public let guardedFolders: [RemotePath]

    public init(home: RemotePath = RemotePath(UserHome.path)) {
        guardedFolders = ["Desktop", "Documents", "Downloads", "Library/CloudStorage", "Library/Mobile Documents"]
            .map { home.appending($0) }
    }

    /// One of the guarded folders itself, or a disk mounted under /Volumes.
    public func isGuardedFolder(_ path: RemotePath) -> Bool {
        guardedFolders.contains(path) || path.parent == "/Volumes"
    }

    /// A guarded folder or anything inside one.
    public func isGuarded(_ path: RemotePath) -> Bool {
        isGuardedFolder(path)
            || guardedFolders.contains { $0.isAncestor(of: path) }
            || RemotePath("/Volumes").isAncestor(of: path)
    }
}
