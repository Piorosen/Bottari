import BottariCore
import Foundation
import Observation

/// One pane: the provider it browses, the folder it shows, its history and selection.
@Observable
final class PaneModel {
    let provider: any FileProvider
    private(set) var path: RemotePath
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var selection: Set<FileItem.ID> = []
    var showsHiddenFiles = false

    private var backStack: [RemotePath] = []
    private var forwardStack: [RemotePath] = []
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var hasStarted = false

    init(provider: any FileProvider, start: RemotePath? = nil) {
        self.provider = provider
        self.path = start ?? provider.home
    }

    var isLocal: Bool { provider is LocalFileProvider }
    var visibleItems: [FileItem] { showsHiddenFiles ? items : items.filter { !$0.isHidden } }
    var selectedItems: [FileItem] { items.filter { selection.contains($0.id) } }
    var canGoBack: Bool { !backStack.isEmpty || path.parent != nil }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Loads the starting folder once; later appearances keep the pane where it was.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await load(path)
    }

    func reload() async {
        await load(path, keepingSelection: true)
    }

    /// Opens a folder and remembers where we came from.
    func open(_ destination: RemotePath) async {
        guard destination != path else { return }
        let origin = path
        if await load(destination) {
            backStack.append(origin)
            forwardStack.removeAll()
        }
    }

    /// Back through history, or up to the parent folder when there is no history (⌫).
    func goBack() async {
        guard let previous = backStack.last else {
            await goUp()
            return
        }
        let origin = path
        if await load(previous) {
            backStack.removeLast()
            forwardStack.append(origin)
            selection = [origin]
        }
    }

    func goForward() async {
        guard let next = forwardStack.last else { return }
        let origin = path
        if await load(next) {
            forwardStack.removeLast()
            backStack.append(origin)
        }
    }

    /// Up one level, selecting the folder we came out of, like Finder.
    func goUp() async {
        guard let parent = path.parent else { return }
        let child = path
        await open(parent)
        if path == parent { selection = [child] }
    }

    /// Double-click or Return: folders open; files get previews and editors in later steps.
    func activate(_ item: FileItem) async {
        if item.isDirectory {
            await open(item.path)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Lists `destination` and shows it. Returns false if it failed or a newer
    /// navigation started meanwhile, in which case the pane stays where it was.
    @discardableResult
    private func load(_ destination: RemotePath, keepingSelection: Bool = false) async -> Bool {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let listing = try await provider.list(destination)
            guard generation == loadGeneration else { return false }
            path = destination
            items = listing
            selection = keepingSelection ? selection.intersection(listing.map(\.id)) : []
            errorMessage = nil
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }
}
