import Foundation

/// The folders and files the user let Bottari use while it runs in the App
/// Sandbox (the App Store edition). The sandbox lets the app into what the
/// user picks in an open panel or drops on it; bookmarks keep that across
/// launches. Outside the sandbox everything is reachable and nothing is kept.
public final class FolderAccess: @unchecked Sendable {
    public static let shared = FolderAccess()

    /// Whether the app runs in the App Sandbox.
    public static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private let defaults: UserDefaults
    private let key = "folderAccess.bookmarks"
    private let lock = NSLock()
    /// Path → the bookmark-resolved URL whose access is open for the whole run.
    private var opened: [String: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// What the user allowed, sorted, for listing them.
    public var paths: [RemotePath] {
        lock.withLock { opened.keys.sorted().map { RemotePath($0) } }
    }

    /// Opens everything allowed earlier; call once at launch.
    public func restore() {
        guard Self.isSandboxed else { return }
        var kept: [Data] = []
        for bookmark in defaults.array(forKey: key) as? [Data] ?? [] {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &isStale),
                  url.startAccessingSecurityScopedResource() else { continue }
            let fresh = isStale ? (try? url.bookmarkData(options: [.withSecurityScope])) : bookmark
            kept.append(fresh ?? bookmark)
            lock.withLock { opened[url.path] = url }
        }
        defaults.set(kept, forKey: key)
    }

    /// Keeps the folder or file the user just picked (or dropped) reachable
    /// from now on, also after relaunching.
    public func remember(_ url: URL) {
        // Something already reachable (inside an allowed folder, Downloads) needs no bookmark of its own.
        guard Self.isSandboxed, !covers(RemotePath(url.path)) else { return }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) else { return }
        _ = url.startAccessingSecurityScopedResource()
        lock.withLock {
            // A folder inside one already kept adds nothing; one around kept ones replaces them.
            for path in opened.keys where RemotePath(url.path).isAncestor(of: RemotePath(path)) {
                opened[path]?.stopAccessingSecurityScopedResource()
                opened[path] = nil
            }
            opened[url.path] = url
        }
        var bookmarks = (defaults.array(forKey: key) as? [Data] ?? []).filter { data in
            var isStale = false
            guard let kept = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &isStale) else { return false }
            return !RemotePath(url.path).isAncestor(of: RemotePath(kept.path)) && kept.path != url.path
        }
        bookmarks.append(bookmark)
        defaults.set(bookmarks, forKey: key)
    }

    /// Stops using a folder the user allowed before.
    public func forget(_ path: RemotePath) {
        lock.withLock {
            opened[path.string]?.stopAccessingSecurityScopedResource()
            opened[path.string] = nil
        }
        let bookmarks = (defaults.array(forKey: key) as? [Data] ?? []).filter { data in
            var isStale = false
            let kept = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &isStale)
            return kept?.path != path.string
        }
        defaults.set(bookmarks, forKey: key)
    }

    /// Whether Bottari can reach `path`: always outside the sandbox; inside it,
    /// in a folder the user allowed, the Downloads folder, or the app's own container.
    public func covers(_ path: RemotePath) -> Bool {
        guard Self.isSandboxed else { return true }
        let always = [RemotePath(NSHomeDirectory()), RemotePath(UserHome.path).appending("Downloads")]
        if always.contains(where: { $0 == path || $0.isAncestor(of: path) }) { return true }
        return lock.withLock { opened.keys.contains { RemotePath($0) == path || RemotePath($0).isAncestor(of: path) } }
    }
}
