import AppKit
import BottariCore
import BottariSFTP
import BottariTransfer
import Observation
import SwiftUI

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
    var showsTransfers = false
    /// Opens viewer windows; the main window sets it, since only views can open windows.
    @ObservationIgnored var viewerOpener: ViewerOpener?

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
            refusal = "‘\(site.name)’ 서버는 읽기 전용으로 열었어요. 쓰려면 연결 관리에서 읽기 전용을 끄세요."
            return
        }
        if request.kind == .move, let site = request.sourceSite, site.readOnly {
            refusal = "‘\(site.name)’ 서버는 읽기 전용이라 원본을 지울 수 없어요. 이동 대신 복사해 주세요."
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
            from: TransferEndpoint(request.source),
            to: TransferEndpoint(request.destination),
            into: request.folder,
            policy: TransferSettings.conflictPolicy
        )
        if request.clearsClipboard {
            AppServices.clipboard.clear()
        }
    }

    // MARK: - Places

    /// Opens a folder on the Mac in the active pane.
    func openOnMac(_ path: RemotePath) {
        let pane = pane(activeSide)
        Task {
            if !pane.provider.isLocal {
                await pane.switchProvider(to: LocalFileProvider())
            }
            await pane.open(path)
        }
    }

    /// Connects the active pane to a saved site.
    func open(_ site: SavedSite) {
        let pane = pane(activeSide)
        Task {
            do {
                try await pane.connect(to: site)
            } catch {
                refusal = "\(site.name)에 연결하지 못했어요: \(error.localizedDescription)"
            }
        }
    }

    func open(_ favorite: Favorites.Favorite) {
        guard let siteID = favorite.siteID else { return openOnMac(favorite.path) }
        guard let site = AppServices.sites.site(siteID) else { return }
        let pane = pane(activeSide)
        Task {
            do {
                if pane.site?.id != siteID { try await pane.connect(to: site) }
                await pane.open(favorite.path)
            } catch {
                refusal = "\(site.name)에 연결하지 못했어요: \(error.localizedDescription)"
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

    // MARK: - File operations

    /// Refuses with an explanation when the pane shows a read-only site.
    private func allowsChanges(in pane: PaneModel) -> Bool {
        guard let site = pane.site, site.readOnly else { return true }
        refusal = "‘\(site.name)’ 서버는 읽기 전용으로 열었어요. 바꾸려면 연결 관리에서 읽기 전용을 끄세요."
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
            pendingDeletion = DeletionRequest(items: items, side: side, site: pane.site, folder: pane.path)
        }
    }

    func confirm(_ deletion: DeletionRequest) {
        pendingDeletion = nil
        let pane = pane(deletion.side)
        Task { await pane.remove(deletion.items, permanently: true) }
    }

    func copyPaths(from side: PaneSide) {
        let text = pane(side).selectedPathsText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Drag and drop

    /// What is being dragged out of a pane. Drags carry only a token; the items
    /// themselves stay here, since remote files have no file URL to hand over.
    private struct PaneDrag {
        let pane: PaneModel
        let items: [FileItem]
    }

    private static let dragTokenPrefix = "bottari-drag:"
    private static var currentDrag: PaneDrag?

    /// The drag contents for `item`: the whole selection when it is selected.
    /// Files on the Mac also carry their URL, so Finder accepts them.
    func dragProvider(for item: FileItem, from side: PaneSide) -> NSItemProvider {
        let pane = pane(side)
        let items = pane.selection.contains(item.id) ? pane.selectedItems : [item]
        Self.currentDrag = PaneDrag(pane: pane, items: items)
        let provider = NSItemProvider(object: (Self.dragTokenPrefix + UUID().uuidString) as NSString)
        if pane.provider.isLocal {
            provider.registerObject(URL(fileURLWithPath: item.path.string) as NSURL, visibility: .all)
        }
        return provider
    }

    /// Items dropped on a pane go into its folder: copied, or moved with ⌘ held.
    func drop(_ providers: [NSItemProvider], onto side: PaneSide) -> Bool {
        let kind: TransferKind = NSEvent.modifierFlags.contains(.command) ? .move : .copy
        let destination = pane(side)
        Task {
            let texts = await Self.loadStrings(from: providers)
            if texts.contains(where: { $0.hasPrefix(Self.dragTokenPrefix) }), let drag = Self.currentDrag {
                Self.currentDrag = nil
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
            let texts = await Self.loadStrings(from: providers)
            if texts.contains(where: { $0.hasPrefix(Self.dragTokenPrefix) }), let drag = Self.currentDrag {
                Self.currentDrag = nil
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

    private static func loadStrings(from providers: [NSItemProvider]) async -> [String] {
        var loaded: [String] = []
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            let text: String? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    continuation.resume(returning: (object as? NSString).map { $0 as String })
                }
            }
            if let text { loaded.append(text) }
        }
        return loaded
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
}

/// The pane with keyboard focus, for the Edit menu's copy and paste.
struct PaneFocus {
    let workspace: Workspace
    let side: PaneSide

    var pane: PaneModel { workspace.pane(side) }
}

extension FocusedValues {
    @Entry var paneFocus: PaneFocus?
}
