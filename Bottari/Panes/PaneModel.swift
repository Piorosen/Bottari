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
    /// The column header clicked last, and its direction. Folders stay on
    /// top either way, as in Finder; the choice carries over to new panes.
    var sortOrder: [KeyPathComparator<FileItem>] = PaneSort.saved {
        didSet {
            guard sortOrder != oldValue else { return }
            items = sorted(items)
            PaneSort.save(sortOrder)
        }
    }
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
    /// Which download the footer and `previewDownload` belong to, so an older
    /// one finishing late does not clear a newer one's.
    @ObservationIgnored private var previewDownloadID: UUID?
    @ObservationIgnored private var downloadStatusID: UUID?
    /// The search field has the keyboard, so file commands leave its keys alone.
    var isTypingInSearch = false

    /// What to find under the folder; nil while the pane shows the folder itself.
    private(set) var searchQuery: String?
    private(set) var searchResults: [FileItem] = []
    private(set) var isSearching = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Matches shown at most; a search stops there.
    static let searchLimit = 500

    private var backStack: [RemotePath] = []
    private var forwardStack: [RemotePath] = []
    private var siteID: SavedSite.ID?
    @ObservationIgnored private var loadGeneration = 0
    /// Bumped by every connect and switch, so only the newest one lands.
    @ObservationIgnored private var placeGeneration = 0
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
    var selectedItems: [FileItem] { items(withIDs: selection) }
    /// What the list shows: search results once something is typed to find,
    /// the folder otherwise.
    var shownItems: [FileItem] {
        guard showsSearchResults else { return visibleItems }
        return sorted(showsHiddenFiles ? searchResults : searchResults.filter { !$0.isHidden })
    }

    /// `list` in `sortOrder`, folders first, names breaking ties.
    func sorted(_ list: [FileItem]) -> [FileItem] {
        let order = sortOrder
        return list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            for comparator in order {
                let result = comparator.compare(a, b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var showsSearchResults: Bool {
        !(searchQuery ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    func items(withIDs ids: Set<FileItem.ID>) -> [FileItem] {
        (showsSearchResults ? searchResults : items).filter { ids.contains($0.id) }
    }
    var canGoBack: Bool { !backStack.isEmpty || path.parent != nil }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Loads the starting folder once; later appearances keep the pane where it was.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await load(path)
    }

    /// Connects to a saved site and shows it in this pane. `typedSecrets` are
    /// passwords the user just typed for it (see `SiteLibrary.connect`).
    /// A connect overtaken by a newer one (the user clicked elsewhere
    /// meanwhile) closes what it opened and throws `CancellationError`.
    func connect(to site: SavedSite, typedSecrets: [String: String] = [:], keepingTypedSecrets: Bool = true) async throws {
        placeGeneration += 1
        let generation = placeGeneration
        connectingSite = site
        defer { if generation == placeGeneration { connectingSite = nil } }
        let provider = try await library.connect(site, typedSecrets: typedSecrets, keepingTypedSecrets: keepingTypedSecrets)
        guard generation == placeGeneration else {
            await AppServices.connections.release(provider)
            throw CancellationError()
        }
        await switchProvider(to: provider, site: site)
    }

    /// Shows a different location in this pane, starting at the site's start
    /// folder or the provider's home, and closes the connection the pane was using before.
    func switchProvider(to newProvider: any FileProvider, site: SavedSite? = nil) async {
        if connectingSite?.id != site?.id || site == nil {
            placeGeneration += 1
            connectingSite = nil
        }
        // Results and downloads from the old place mean nothing here.
        endSearch()
        cancelPreviewDownload()
        renaming = nil
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
            errorMessage = String(localized: "시작 폴더를 열 수 없어 홈 폴더를 열었습니다: \(start.string)")
        }
        await AppServices.connections.release(previous)
    }

    /// Lets go of the pane's connection, e.g. when its window closes. It stays
    /// open while a transfer still uses it.
    func disconnect() async {
        await AppServices.connections.release(provider)
    }

    func selectAll() {
        selection = Set(shownItems.map(\.id))
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
            if job.kind == .move, job.source.provider.locationID == here {
                forgetResults(job.items.map(\.path))
            }
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

    func showError(_ message: String) {
        errorMessage = message
    }

    // MARK: - Search

    func beginSearch() {
        if searchQuery == nil { searchQuery = "" }
    }

    /// Looks for `query` under the folder, a moment after the typing stops.
    func search(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        searchResults = []
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        let provider = provider
        let folder = path
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                for try await item in provider.search(query, in: folder, limit: Self.searchLimit) {
                    guard !Task.isCancelled else { return }
                    self?.searchResults.append(item)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
            // A cancelled search ends quietly too; the newer one owns the spinner.
            guard !Task.isCancelled else { return }
            self?.isSearching = false
        }
    }

    func endSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = nil
        searchResults = []
        isSearching = false
        isTypingInSearch = false
    }

    /// Drops results that are gone: trashed, deleted, renamed or moved away.
    private func forgetResults(_ paths: [RemotePath]) {
        guard !searchResults.isEmpty else { return }
        let gone = Set(paths)
        searchResults.removeAll { item in
            gone.contains(item.path) || gone.contains { item.path.string.hasPrefix($0.string + "/") }
        }
        selection.subtract(paths)
    }

    /// Opens the folder holding a search result, with the result selected.
    func reveal(_ item: FileItem) async {
        guard let parent = item.path.parent else { return }
        endSearch()
        await open(parent)
        if path == parent { selection = [item.id] }
    }

    /// Where a result sits, relative to the folder searched: "logs/old".
    func searchLocation(of item: FileItem) -> String {
        guard let parent = item.path.parent, parent != path else { return "" }
        let prefix = path.string.hasSuffix("/") ? path.string : path.string + "/"
        return parent.string.hasPrefix(prefix) ? String(parent.string.dropFirst(prefix.count)) : parent.string
    }

    // MARK: - Quick Look

    /// Space: previews the selection, or closes the preview. Files on a server
    /// are downloaded to the cache first; Space again stops the download.
    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        if previewDownload != nil {
            cancelPreviewDownload()
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
        let id = UUID()
        previewDownloadID = id
        previewDownload = Task {
            defer {
                if previewDownloadID == id {
                    previewDownload = nil
                    previewDownloadID = nil
                }
            }
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

    private func cancelPreviewDownload() {
        previewDownload?.cancel()
        previewDownload = nil
        previewDownloadID = nil
        downloadStatus = nil
        downloadStatusID = nil
    }

    /// A local copy of a server file through the cache, reporting progress in the footer.
    func download(_ item: FileItem) async throws -> URL {
        let total = item.size.map { ByteFormat.string($0) }
        let id = UUID()
        downloadStatusID = id
        downloadStatus = String(localized: "받는 중…")
        defer {
            if downloadStatusID == id {
                downloadStatus = nil
                downloadStatusID = nil
            }
        }
        return try await AppServices.fileCache.localURL(for: item, from: provider) { [weak self] received in
            let text = String(localized: "받는 중 · \(ByteFormat.string(received))") + (total.map { " / \($0)" } ?? "")
            Task { @MainActor in
                if self?.downloadStatusID == id { self?.downloadStatus = text }
            }
        }
    }

    // MARK: - File operations

    /// Creates "새 폴더" (or the next free name) and starts renaming it, like Finder.
    func makeFolder() async {
        let name = FileNames.available(String(localized: "새 폴더"), isDirectory: true, taken: Set(items.map(\.name)))
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
        if showsSearchResults, let index = searchResults.firstIndex(where: { $0.id == item.id }) {
            if let renamed = try? await provider.stat(target) {
                searchResults[index] = renamed
            } else {
                searchResults.remove(at: index)
            }
        }
        await reload()
        selection = [target]
    }

    /// Which items under a chosen folder a permission change reaches.
    enum PermissionScope: CaseIterable {
        case chosenOnly, everything, filesOnly, foldersOnly

        var title: String {
            switch self {
            case .chosenOnly: String(localized: "선택한 항목만")
            case .everything: String(localized: "하위 폴더와 파일 모두")
            case .filesOnly: String(localized: "하위 파일만")
            case .foldersOnly: String(localized: "하위 폴더만")
            }
        }
    }

    /// Sets `mode` on the chosen items and, by `scope`, on what is inside the
    /// chosen folders. Linked folders are not entered.
    func setPermissions(_ mode: UInt16, on chosen: [FileItem], scope: PermissionScope) async {
        isLoading = true
        do {
            for item in chosen {
                try await provider.setPermissions(mode, at: item.path)
                if item.isDirectory, !item.isSymbolicLink, scope != .chosenOnly {
                    try await setPermissions(mode, inside: item.path, scope: scope)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    private func setPermissions(_ mode: UInt16, inside folder: RemotePath, scope: PermissionScope) async throws {
        for child in try await provider.list(folder) {
            let applies = scope == .everything || (scope == .filesOnly) != child.isDirectory
            if applies, !child.isSymbolicLink {
                try await provider.setPermissions(mode, at: child.path)
            }
            if child.isDirectory, !child.isSymbolicLink {
                try await setPermissions(mode, inside: child.path, scope: scope)
            }
        }
    }

    /// Makes "<name> 링크" here pointing at `item`, and starts renaming it like
    /// Finder's Make Alias. The link holds the bare name when the item is in
    /// this folder, so it survives the folder moving; its full path otherwise.
    func makeLink(to item: FileItem) async {
        let name = FileNames.available(String(localized: "\(item.name) 링크"), isDirectory: false, taken: Set(items.map(\.name)))
        let link = path.appending(name)
        do {
            try await provider.makeSymbolicLink(at: link, to: item.path.parent == path ? item.name : item.path.string)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        endSearch()
        await reload()
        selection = [link]
        renaming = link
    }

    /// Moves items to the trash where the provider has one, otherwise deletes them.
    func remove(_ doomed: [FileItem], permanently: Bool) async {
        let trash = !permanently && provider.capabilities.contains(.trash)
        isLoading = true
        var removed: [RemotePath] = []
        for item in doomed {
            do {
                if trash {
                    try await provider.trash(item.path)
                } else {
                    try await provider.delete(item.path)
                }
                removed.append(item.path)
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        forgetResults(removed)
        await reload()
    }

    /// Packs items into "<name>.tar.gz" (or "보관함.tar.gz" for several) on the server.
    func compressOnServer(_ chosen: [FileItem]) async {
        guard let server = provider as? SFTPFileProvider, let first = chosen.first else { return }
        let base = chosen.count == 1 ? first.name : String(localized: "보관함")
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
        let folder = path.appending(FileNames.available(name.isEmpty ? String(localized: "풀린 파일") : name, isDirectory: true, taken: Set(items.map(\.name))))
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
            if destination != path {
                endSearch()
                cancelPreviewDownload()
            }
            path = destination
            items = sorted(listing)
            if searchQuery == nil {
                selection = keepingSelection ? selection.intersection(listing.map(\.id)) : []
            }
            errorMessage = nil
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// The pane sort as kept between launches: which column, which way.
enum PaneSort {
    private static let key = "panes.sort"
    private static var columns: [(name: String, comparator: KeyPathComparator<FileItem>)] {[
        ("name", KeyPathComparator(\.name, comparator: .localizedStandard)),
        ("size", KeyPathComparator(\.sizeForSorting)),
        ("modified", KeyPathComparator(\.dateForSorting)),
    ]}

    static var saved: [KeyPathComparator<FileItem>] {
        let text = UserDefaults.standard.string(forKey: key) ?? "name"
        let descending = text.hasPrefix("-")
        guard var comparator = columns.first(where: { $0.name == text.trimmingCharacters(in: ["-"]) })?.comparator else { return [columns[0].comparator] }
        comparator.order = descending ? .reverse : .forward
        return [comparator]
    }

    static func save(_ order: [KeyPathComparator<FileItem>]) {
        guard let first = order.first, let column = columns.first(where: { $0.comparator.keyPath == first.keyPath }) else { return }
        UserDefaults.standard.set((first.order == .reverse ? "-" : "") + column.name, forKey: key)
    }
}

extension FileItem {
    /// Sizes to sort by; folders and unknown sizes come first.
    nonisolated var sizeForSorting: Int64 { size ?? -1 }
    nonisolated var dateForSorting: Date { modified ?? .distantPast }
}
