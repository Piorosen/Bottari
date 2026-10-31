import AppKit
import BottariCore
import BottariSFTP
import BottariTransfer
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum PaneSide {
    case left, right

    var other: PaneSide { self == .left ? .right : .left }
}

/// A copy or move about to be queued, with the sites on both sides for the
/// read-only and confirm-before-writing checks.
struct TransferRequest: Identifiable {
    let id = UUID()
    let kind: TransferKind
    let items: [FileItem]
    let source: any FileProvider
    let sourceSite: SavedSite?
    let destination: any FileProvider
    let destinationSite: SavedSite?
    let folder: RemotePath
    /// ⌥⌘V empties the clipboard once the move is queued.
    var clearsClipboard = false
}

/// One window: two panes side by side, and what moves between them.
@Observable
final class Workspace {
    let left: PaneModel
    let right: PaneModel
    var activeSide: PaneSide = .left
    /// A transfer touching a site marked "confirm before writing", waiting for the user.
    var pendingConfirmation: TransferRequest?
    /// Items waiting for the user to confirm deleting them for good.
    var pendingDeletion: DeletionRequest?
    /// Why the last transfer was refused, e.g. a read-only site.
    var refusal: String?
    var showsPalette = false
    /// The preview column right of the panes.
    var showsInspector = true
    /// How much of the width the left pane takes.
    var paneRatio: CGFloat = 0.5
    /// The connection manager, opened from the toolbar or the sidebar.
    var siteManager: SiteManagerRequest?
    /// A connection waiting for the user to type a password.
    var passwordRequest: PasswordRequest?
    /// The pane that should take keyboard focus next, e.g. after ⇥.
    var focusRequest: PaneSide?
    /// The pane that should open its search field (⌘F).
    var searchRequest: PaneSide?
    /// Opens viewer windows; the main window sets it, since only views can open windows.
    @ObservationIgnored var viewerOpener: ViewerOpener?
    /// The main window used last, for requests from elsewhere (Settings) to land in.
    @ObservationIgnored static weak var lastActive: Workspace?

    init(left: PaneModel = PaneModel(provider: LocalFileProvider()), right: PaneModel = PaneModel(provider: LocalFileProvider())) {
        self.left = left
        self.right = right
    }

    func pane(_ side: PaneSide) -> PaneModel {
        side == .left ? left : right
    }

    // MARK: - Starting transfers

    /// Copies or moves items of one pane into the folder the other pane shows.
    func send(_ items: [FileItem], from side: PaneSide, kind: TransferKind) {
        let source = pane(side)
        let destination = pane(side.other)
        request(TransferRequest(
            kind: kind,
            items: items,
            source: source.provider,
            sourceSite: source.site,
            destination: destination.provider,
            destinationSite: destination.site,
            folder: destination.path
        ))
    }

    func copyToClipboard(from side: PaneSide) {
        let pane = pane(side)
        AppServices.clipboard.copy(pane.selectedItems, from: pane.provider, site: pane.site)
    }

    func paste(into side: PaneSide, kind: TransferKind) {
        guard let content = AppServices.clipboard.content else { return }
        let destination = pane(side)
        var request = TransferRequest(
            kind: kind,
            items: content.items,
            source: content.provider,
            sourceSite: content.siteID.flatMap(AppServices.sites.site),
            destination: destination.provider,
            destinationSite: destination.site,
            folder: destination.path
        )
        request.clearsClipboard = kind == .move
        self.request(request)
    }

    /// Queues the transfer unless a read-only site refuses it or a guarded site
    /// wants the user to confirm first.
    func request(_ request: TransferRequest) {
        guard !request.items.isEmpty else { return }
        if let site = request.destinationSite, site.readOnly {
            refusal = String(localized: "‘\(site.name)’ 서버는 읽기 전용입니다. 파일을 쓰려면 연결 관리에서 읽기 전용을 끄십시오.")
            return
        }
        if request.kind == .move, let site = request.sourceSite, site.readOnly {
            refusal = String(localized: "‘\(site.name)’ 서버는 읽기 전용이므로 원본을 삭제할 수 없습니다. 이동 대신 복사하십시오.")
            return
        }
        if request.destinationSite?.confirmsWrites == true || (request.kind == .move && request.sourceSite?.confirmsWrites == true) {
            pendingConfirmation = request
            return
        }
        start(request)
    }

    /// The user confirmed writing to a guarded site.
    func confirm(_ request: TransferRequest) {
        pendingConfirmation = nil
        start(request)
    }

    private func start(_ request: TransferRequest) {
        AppServices.transfers.enqueue(
            request.kind,
            request.items,
            from: TransferEndpoint(request.source, place: TransferRecords.place(for: request.source, site: request.sourceSite)),
            to: TransferEndpoint(request.destination, place: TransferRecords.place(for: request.destination, site: request.destinationSite)),
            into: request.folder,
            policy: TransferSettings.conflictPolicy
        )
        if request.clearsClipboard {
            AppServices.clipboard.clear()
        }
    }

    // MARK: - Places

    /// Opens a folder on the Mac in the active pane, or in `side`.
    func openOnMac(_ path: RemotePath, in side: PaneSide? = nil) {
        if let side { activeSide = side }
        let pane = pane(side ?? activeSide)
        Task {
            if !pane.provider.isLocal {
                await pane.switchProvider(to: LocalFileProvider())
            }
            await pane.open(path)
        }
    }

    /// Connects the active pane to a saved site.
    func open(_ site: SavedSite) {
        connect(site, in: activeSide)
    }

    func open(_ favorite: Favorites.Favorite) {
        guard let siteID = favorite.siteID else { return openOnMac(favorite.path) }
        guard let site = AppServices.sites.site(siteID) else {
            refusal = String(localized: "‘\(favorite.name)’ 즐겨찾기의 연결이 삭제되었습니다. 사이드바에서 오른쪽 클릭해 제거하십시오.")
            return
        }
        let pane = pane(activeSide)
        if pane.site?.id == siteID {
            Task { await pane.open(favorite.path) }
        } else {
            connect(site, in: activeSide, then: { pane in await pane.open(favorite.path) })
        }
    }

    /// Connects a pane to `site`, then runs `then`. When a password is missing
    /// or refused, asks for it and tries again; other failures go to `failed`,
    /// or to the refusal alert without one.
    func connect(
        _ site: SavedSite,
        in side: PaneSide,
        typedSecrets: [String: String] = [:],
        keepingTypedSecrets: Bool = true,
        failed: ((any Error) -> Void)? = nil,
        then: ((PaneModel) async -> Void)? = nil
    ) {
        let pane = pane(side)
        Task {
            do {
                try await pane.connect(to: site, typedSecrets: typedSecrets, keepingTypedSecrets: keepingTypedSecrets)
                await then?(pane)
            } catch is CancellationError {
                // Overtaken by another place chosen for the pane meanwhile.
            } catch {
                if let request = PasswordRequest(site: site, side: side, error: error, typed: typedSecrets, sites: pane.library.sites, failed: failed, then: then) {
                    passwordRequest = request
                } else if let failed {
                    failed(error)
                } else {
                    refusal = String(localized: "\(site.name)에 연결할 수 없습니다: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Tries the connection again with what the user typed into the password sheet.
    func answer(_ request: PasswordRequest, with secret: String, keeping: Bool) {
        passwordRequest = nil
        var typed = request.typed
        typed[request.key] = secret
        connect(request.site, in: request.side, typedSecrets: typed, keepingTypedSecrets: keeping, failed: request.failed, then: request.then)
    }

    /// The two panes trade places.
    func swapPanes() {
        left.exchange(with: right)
        activeSide = activeSide.other
        focusRequest = activeSide
    }

    /// Shows the folder of the pane on `side` in the other pane as well:
    /// the same place on the Mac, or a connection of its own to the same site.
    func showInOtherPane(from side: PaneSide) {
        let source = pane(side)
        let target = pane(side.other)
        let folder = source.path
        if source.provider.isLocal {
            Task {
                if !target.provider.isLocal { await target.switchProvider(to: LocalFileProvider()) }
                await target.open(folder)
            }
        } else if let site = source.site {
            if target.site?.id == site.id {
                Task { await target.open(folder) }
            } else {
                connect(site, in: side.other, then: { await $0.open(folder) })
            }
        }
    }

    func isOpen(_ site: SavedSite) -> Bool {
        left.site?.id == site.id || right.site?.id == site.id
    }

    func addToBundle(from side: PaneSide, items: [FileItem]? = nil) {
        let pane = pane(side)
        BottariBundle.shared.add(items ?? pane.selectedItems, from: pane.provider, site: pane.site)
    }

    func addFavorite(_ item: FileItem, in side: PaneSide) {
        Favorites.shared.add(item.path, site: pane(side).site)
    }

    // MARK: - Opening files

    /// Double-click, Return-less open (⌘↓): folders open in the pane, images in
    /// the gallery, anything else in Quick Look.
    func open(_ item: FileItem, in side: PaneSide) {
        let pane = pane(side)
        if item.isDirectory || (item.isSymbolicLink && item.kind == .other) {
            Task { await pane.activate(item) }
            return
        }
        switch FileKind(item) {
        case .image:
            openViewer("gallery", for: item, in: pane)
        case .text where (item.size ?? 0) <= EditorModel.sizeLimit:
            openViewer("editor", for: item, in: pane)
        case .video:
            openViewer("player", for: item, in: pane)
        case .text, .other:
            pane.selection = [item.id]
            pane.toggleQuickLook()
        }
    }

    /// A shell on the pane's server, starting in the folder it shows.
    func openTerminal(in side: PaneSide) {
        let pane = pane(side)
        guard pane.provider is SFTPFileProvider else { return }
        openViewer("terminal", for: FileItem(path: pane.path, kind: .directory), in: pane)
    }

    /// The site's VNC or Screen Sharing session.
    func openScreen(in side: PaneSide) {
        let pane = pane(side)
        guard pane.provider is SFTPFileProvider, pane.site?.remoteScreen != nil else { return }
        openViewer("screen", for: FileItem(path: pane.path, kind: .directory), in: pane)
    }

    func openInEditor(_ item: FileItem, in side: PaneSide) {
        openViewer("editor", for: item, in: pane(side))
    }

    private func openViewer(_ windowID: String, for item: FileItem, in pane: PaneModel) {
        guard let opener = viewerOpener else { return }
        let context = ViewerContext(provider: pane.provider, site: pane.site, item: item, siblings: pane.visibleItems)
        opener.open(windowID, Viewers.register(context))
    }

    // MARK: - Shortcuts

    /// What a key from the keymap does to the pane on `side`.
    func perform(_ action: PaneAction, in side: PaneSide) {
        let pane = pane(side)
        let selected = pane.selectedItems
        switch action {
        case .copyToOther:
            if !selected.isEmpty { send(selected, from: side, kind: .copy) }
        case .moveToOther:
            if !selected.isEmpty { send(selected, from: side, kind: .move) }
        case .newFolder:
            makeFolder(in: side)
        case .rename:
            if selected.count == 1 { beginRenaming(in: side) }
        case .delete:
            delete(selected, in: side)
        case .preview:
            pane.toggleQuickLook()
        case .edit:
            if selected.count == 1, let item = selected.first, !item.isDirectory { openInEditor(item, in: side) }
        case .bundle:
            if !selected.isEmpty { addToBundle(from: side) }
        case .switchPane:
            activeSide = side.other
            focusRequest = side.other
        case .palette:
            showsPalette = true
        }
    }

    // MARK: - File operations

    /// Refuses with an explanation when the pane shows a read-only site.
    private func allowsChanges(in pane: PaneModel) -> Bool {
        guard let site = pane.site, site.readOnly else { return true }
        refusal = String(localized: "‘\(site.name)’ 서버는 읽기 전용입니다. 변경하려면 연결 관리에서 읽기 전용을 끄십시오.")
        return false
    }

    func makeFolder(in side: PaneSide) {
        let pane = pane(side)
        guard allowsChanges(in: pane) else { return }
        Task { await pane.makeFolder() }
    }

    func beginRenaming(in side: PaneSide) {
        let pane = pane(side)
        guard allowsChanges(in: pane) else { return }
        pane.beginRenaming()
    }

    /// The Mac's own files go to the Trash straight away, as in Finder; deleting
    /// on a server cannot be undone, so it asks first.
    func delete(_ items: [FileItem], in side: PaneSide) {
        let pane = pane(side)
        guard !items.isEmpty, allowsChanges(in: pane) else { return }
        if pane.provider.capabilities.contains(.trash) {
            Task { await pane.remove(items, permanently: false) }
        } else {
            pendingDeletion = DeletionRequest(items: items, side: side, site: pane.site, folder: pane.path, locationID: pane.provider.locationID)
        }
    }

    func confirm(_ deletion: DeletionRequest) {
        pendingDeletion = nil
        let pane = pane(deletion.side)
        // The pane may have moved to another server while the sheet was up;
        // the same paths there are other files.
        if let place = deletion.locationID, pane.provider.locationID != place {
            refusal = String(localized: "패인이 다른 위치로 바뀌어 삭제하지 않았습니다.")
            return
        }
        Task { await pane.remove(deletion.items, permanently: true) }
    }

    func copyPaths(from side: PaneSide) {
        let text = pane(side).selectedPathsText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Drag and drop

    /// What is being dragged out of a pane. Drags carry only a token, under a
    /// type other apps cannot see; the items themselves stay here, since
    /// remote files have no file URL to hand over.
    private struct PaneDrag {
        let token: String
        let pane: PaneModel
        let items: [FileItem]
    }

    private static var currentDrag: PaneDrag?

    /// The drag contents for `item`: the whole selection when it is selected.
    /// Files on the Mac also carry their URL, so Finder accepts them.
    func dragProvider(for item: FileItem, from side: PaneSide) -> NSItemProvider {
        let pane = pane(side)
        let items = pane.selection.contains(item.id) ? pane.selectedItems : [item]
        let token = UUID().uuidString
        Self.currentDrag = PaneDrag(token: token, pane: pane, items: items)
        let provider = pane.provider.isLocal ? NSItemProvider(object: URL(fileURLWithPath: item.path.string) as NSURL) : NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.bottariPaneItems.identifier, visibility: .ownProcess) { completion in
            completion(Data(token.utf8), nil)
            return nil
        }
        return provider
    }

    /// The pane drag these providers carry, if they come from one.
    private static func paneDrag(in providers: [NSItemProvider]) async -> PaneDrag? {
        guard let carrier = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.bottariPaneItems.identifier) }) else { return nil }
        let token: String? = await withCheckedContinuation { continuation in
            _ = carrier.loadDataRepresentation(forTypeIdentifier: UTType.bottariPaneItems.identifier) { data, _ in
                continuation.resume(returning: data.map { String(decoding: $0, as: UTF8.self) })
            }
        }
        guard let drag = currentDrag, drag.token == token else { return nil }
        currentDrag = nil
        return drag
    }

    /// Items dropped on a pane go into its folder: copied, or moved with ⌘ held.
    func drop(_ providers: [NSItemProvider], onto side: PaneSide) -> Bool {
        let kind: TransferKind = NSEvent.modifierFlags.contains(.command) ? .move : .copy
        let destination = pane(side)
        Task {
            if let drag = await Self.paneDrag(in: providers) {
                // Dropped back where it came from.
                guard drag.pane !== destination else { return }
                request(TransferRequest(
                    kind: kind,
                    items: drag.items,
                    source: drag.pane.provider,
                    sourceSite: drag.pane.site,
                    destination: destination.provider,
                    destinationSite: destination.site,
                    folder: destination.path
                ))
                return
            }
            // Files from Finder.
            let local = LocalFileProvider()
            var items: [FileItem] = []
            for url in await Self.loadFileURLs(from: providers) {
                if let item = try? await local.stat(RemotePath(url.path)) {
                    items.append(item)
                }
            }
            guard !items.isEmpty else { return }
            request(TransferRequest(
                kind: kind,
                items: items,
                source: local,
                sourceSite: nil,
                destination: destination.provider,
                destinationSite: destination.site,
                folder: destination.path
            ))
        }
        return true
    }

    /// Items dragged from a pane or Finder onto the bundle.
    func dropIntoBundle(_ providers: [NSItemProvider]) -> Bool {
        Task {
            if let drag = await Self.paneDrag(in: providers) {
                BottariBundle.shared.add(drag.items, from: drag.pane.provider, site: drag.pane.site)
                return
            }
            let local = LocalFileProvider()
            var items: [FileItem] = []
            for url in await Self.loadFileURLs(from: providers) {
                if let item = try? await local.stat(RemotePath(url.path)) { items.append(item) }
            }
            BottariBundle.shared.add(items, from: local, site: nil)
        }
        return true
    }

    private static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var loaded: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: NSURL.self) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    continuation.resume(returning: (object as? NSURL).map { $0 as URL })
                }
            }
            if let url, url.isFileURL { loaded.append(url) }
        }
        return loaded
    }
}

/// Items to delete for good, waiting for the user's yes.
struct DeletionRequest: Identifiable {
    let id = UUID()
    let items: [FileItem]
    let side: PaneSide
    let site: SavedSite?
    let folder: RemotePath
    /// The provider the items were chosen on.
    var locationID: String?
}

/// The pane with keyboard focus, for the Edit menu's copy and paste.
struct PaneFocus {
    let workspace: Workspace
    let side: PaneSide

    var pane: PaneModel { workspace.pane(side) }
}

extension UTType {
    /// Items dragged out of a pane (declared in Info.plist).
    static let bottariPaneItems = UTType(exportedAs: "io.github.piorosen.bottari.pane-items")
}

extension FocusedValues {
    @Entry var paneFocus: PaneFocus?
    /// The workspace of the main window in front, for menu commands that are
    /// about the window rather than a pane (the preview column).
    @Entry var workspace: Workspace?
}
