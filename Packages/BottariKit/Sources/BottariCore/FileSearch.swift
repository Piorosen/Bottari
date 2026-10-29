import Foundation

/// Finding items by name under a folder, for providers that can only list.
public enum FileSearch {
    /// Whether `name` matches `query`: a `*`/`?` pattern when it has either,
    /// otherwise a substring. Case does not matter.
    public static func matches(_ name: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return false }
        if query.contains(where: { $0 == "*" || $0 == "?" }) {
            return fnmatch(query.lowercased(), name.lowercased(), 0) == 0
        }
        return name.localizedCaseInsensitiveContains(query)
    }

    /// Lists folders breadth first, nearest matches first. Linked folders are
    /// not entered, since they can loop, nor folders `enters` turns down;
    /// folders that cannot be listed are passed over.
    public static func walk(
        _ provider: some FileProvider,
        from folder: RemotePath,
        matching query: String,
        limit: Int,
        enters: @escaping @Sendable (FileItem) -> Bool = { _ in true }
    ) -> AsyncThrowingStream<FileItem, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var queue = [folder]
                var found = 0
                while !queue.isEmpty, found < limit {
                    try Task.checkCancellation()
                    let current = queue.removeFirst()
                    guard let children = try? await provider.list(current) else { continue }
                    for child in children {
                        if matches(child.name, query: query) {
                            continuation.yield(child)
                            found += 1
                            if found == limit { break }
                        }
                        if child.isDirectory, !child.isSymbolicLink, enters(child) {
                            queue.append(child.path)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
