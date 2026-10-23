import BottariCore
import BottariSFTP
import BottariTransfer
import Foundation
import Observation

/// One pane: the provider it browses, the folder it shows, its history and selection.
@Observable
final class PaneModel {
    let library: SiteLibrary
    private(set) var provider: any FileProvider
    private(set) var path: RemotePath
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The saved site being connected to from the pane's menu.
    private(set) var connectingSite: SavedSite?
    var selection: Set<FileItem.ID> = []
    var showsHiddenFiles = ThemeStore.shared.current.list.showHidden
    var viewMode = ViewMode.list

    enum ViewMode: CaseIterable {
        case list, grid
    }
    /// The row whose name is being edited in place.
    var renaming: FileItem.ID?
    /// What Quick Look shows (Space), and the files it can step through.
    var quickLookURL: URL?
    private(set) var quickLookURLs: [URL] = []
    /// "미리보기 받는 중 · 12 MB / 40 MB" while a server file downloads for a preview.
    private(set) var downloadStatus: String?
    @ObservationIgnored private var previewDownload: Task<Void, Never>?

    private var backStack: [RemotePath] = []
    private var forwardStack: [RemotePath] = []
    private var siteID: SavedSite.ID?
    @ObservationIgnored private var loadGeneration = 0
    /// Ended transfers this pane has already reloaded for.
    @ObservationIgnored private var seenTransfers: Set<TransferJob.ID> = []
    @ObservationIgnored private var hasStarted = false

    init(provider: any FileProvider, start: RemotePath? = nil, library: SiteLibrary = AppServices.sites) {
        self.library = library
        self.provider = provider
        self.path = start ?? provider.home
    }

    var isLocal: Bool { provider is LocalFileProvider }
    /// The saved site this pane shows, as currently saved, so tag edits show up at once.
    var site: SavedSite? { siteID.flatMap(library.site) }
    /// `user@host` for remote panes, nil for the Mac.
    var remoteAddress: String? {
        (provider as? SFTPFileProvider).map { "\($0.endpoint.username)@\($0.endpoint.hostKeyID)" }
    }
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

    /// Connects to a saved site and shows it in this pane.
    func connect(to site: SavedSite) async throws {
        connectingSite = site
        defer { connectingSite = nil }
        let provider = try await library.connect(site)
        await switchProvider(to: provider, site: site)
    }

    /// Shows a different location in this pane, starting at the site's start
    /// folder or the provider's home, and closes the connection the pane was using before.
    func switchProvider(to newProvider: any FileProvider, site: SavedSite? = nil) async {
        let previous = provider
        provider = newProvider
        siteID = site?.id
        let start = site?.startLocation(home: newProvider.home) ?? newProvider.home
        path = start
        items = []
        selection = []
        backStack = []
        forwardStack = []
        hasStarted = true
        if await !load(start), start != newProvider.home, await load(newProvider.home) {
            errorMessage = "시작 폴더를 열지 못해서 홈 폴더를 열었어요: \(start.string)"
        }
        await AppServices.connections.release(previous)
    }

    /// Lets go of the pane's connection, e.g. when its window closes. It stays
    /// open while a transfer still uses it.
    func disconnect() async {
        await AppServices.connections.release(provider)
    }

    func selectAll() {
        selection = Set(visibleItems.map(\.id))
    }

    /// Reloads if a transfer that just ended wrote into this folder or moved files out of it.
    func refreshAfterTransfers(_ jobs: [TransferJob]) {
        let here = provider.locationID
        var touched = false
        for job in jobs where job.state.hasEnded && !seenTransfers.contains(job.id) {
            seenTransfers.insert(job.id)
            let wroteHere = job.destination.provider.locationID == here && job.destinationFolder == path
            let movedOut = job.kind == .move && job.source.provider.locationID == here && job.items.contains { $0.path.parent == path }
            touched = touched || wroteHere || movedOut
        }
        if touched {
            Task { await reload() }
        }
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
        } else if item.isSymbolicLink, item.kind == .other {
            // A link the listing did not follow (it points into a privacy-guarded
            // folder). Follow it now that the user asked; macOS may ask first.
            do {
                if try await provider.stat(item.path).isDirectory {
                    await open(item.path)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Quick Look

    /// Space: previews the selection, or closes the preview. Files on a server
    /// are downloaded to the cache first; Space again stops the download.
    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        if let download = previewDownload {
            download.cancel()
            previewDownload = nil
            downloadStatus = nil
            return
        }
        let chosen = selectedItems
        guard let first = chosen.first else { return }
        if provider.isLocal {
            quickLookURLs = chosen.map { URL(fileURLWithPath: $0.path.string) }
            quickLookURL = quickLookURLs.first
            return
        }
        guard !first.isDirectory else { return }
        previewDownload = Task {
            defer { previewDownload = nil }
            do {
                let url = try await download(first)
                guard !Task.isCancelled else { return }
                quickLookURLs = [url]
                quickLookURL = url
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// A local copy of a server file through the cache, reporting progress in the footer.
    func download(_ item: FileItem) async throws -> URL {
        let total = item.size.map { ByteFormat.string($0) }
        downloadStatus = "받는 중…"
        defer { downloadStatus = nil }
        return try await AppServices.fileCache.localURL(for: item, from: provider) { [weak self] received in
            let text = "받는 중 · \(ByteFormat.string(received))" + (total.map { " / \($0)" } ?? "")
            Task { @MainActor in
                if self?.downloadStatus != nil { self?.downloadStatus = text }
            }
        }
    }

    // MARK: - File operations

    /// Creates "새 폴더" (or the next free name) and starts renaming it, like Finder.
    func makeFolder() async {
        let name = FileNames.available("새 폴더", isDirectory: true, taken: Set(items.map(\.name)))
        let folder = path.appending(name)
        do {
            try await provider.makeDirectory(folder)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await reload()
        selection = [folder]
        renaming = folder
    }

    func beginRenaming() {
        guard selection.count == 1, let id = selection.first else { return }
        renaming = id
    }

    func rename(_ item: FileItem, to name: String) async {
        renaming = nil
        guard name != item.name, let parent = item.path.parent else { return }
        if let problem = FileNames.problem(with: name) {
            errorMessage = problem
            return
        }
        let target = parent.appending(name)
        do {
            try await provider.move(item.path, to: target)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await reload()
        selection = [target]
    }

    /// Moves items to the trash where the provider has one, otherwise deletes them.
    func remove(_ doomed: [FileItem], permanently: Bool) async {
        let trash = !permanently && provider.capabilities.contains(.trash)
        isLoading = true
        for item in doomed {
            do {
                if trash {
                    try await provider.trash(item.path)
                } else {
                    try await provider.delete(item.path)
                }
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        await reload()
    }

    /// Packs items into "<name>.tar.gz" (or "보관함.tar.gz" for several) on the server.
    func compressOnServer(_ chosen: [FileItem]) async {
        guard let server = provider as? SFTPFileProvider, let first = chosen.first else { return }
        let base = chosen.count == 1 ? first.name : "보관함"
        let archive = path.appending(FileNames.available("\(base).tar.gz", isDirectory: false, taken: Set(items.map(\.name))))
        await runOnServer {
            try await server.compress(chosen.map(\.path), into: archive)
        }
        selection = [archive]
    }

    /// Unpacks an archive into a new folder named after it.
    func extractOnServer(_ archive: FileItem) async {
        guard let server = provider as? SFTPFileProvider else { return }
        let name = archive.name.replacingOccurrences(of: #"\.(tar\.(gz|bz2|xz)|tgz|tar|zip)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let folder = path.appending(FileNames.available(name.isEmpty ? "풀린 파일" : name, isDirectory: true, taken: Set(items.map(\.name))))
        await runOnServer {
            try await server.extract(archive.path, into: folder)
        }
        selection = [folder]
    }

    private func runOnServer(_ work: () async throws -> Void) async {
        isLoading = true
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    /// Whether the pane's server lets Bottari run commands, for the archive actions.
    var canRunCommands: Bool { (provider as? SFTPFileProvider)?.canRunCommands == true }

    static func isArchive(_ item: FileItem) -> Bool {
        !item.isDirectory && item.name.range(of: #"\.(tar\.(gz|bz2|xz)|tgz|tar|zip)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Paths of the selected items, one per line, for ⌥⌘C.
    var selectedPathsText: String {
        let paths = selectedItems.map(\.path.string).joined(separator: "\n")
        guard let address = remoteAddress else { return paths }
        return selectedItems.map { "\(address):\($0.path.string)" }.joined(separator: "\n")
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
