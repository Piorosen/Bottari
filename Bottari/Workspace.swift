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
    /// Why the last transfer was refused, e.g. a read-only site.
    var refusal: String?
    var showsTransfers = false

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

/// The pane with keyboard focus, for the Edit menu's copy and paste.
struct PaneFocus {
    let workspace: Workspace
    let side: PaneSide

    var pane: PaneModel { workspace.pane(side) }
}

extension FocusedValues {
    @Entry var paneFocus: PaneFocus?
}
