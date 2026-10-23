import BottariCore
import BottariSFTP
import Foundation
import Observation

/// Files copied with ⌘C, to paste with ⌘V into any pane. Kept inside the app:
/// remote files have no place on the system pasteboard.
@Observable
final class FileClipboard {
    struct Content {
        let items: [FileItem]
        let provider: any FileProvider
        let siteID: SavedSite.ID?
    }

    private(set) var content: Content?

    func copy(_ items: [FileItem], from provider: any FileProvider, site: SavedSite?) {
        content = items.isEmpty ? nil : Content(items: items, provider: provider, siteID: site?.id)
    }

    /// After a move-paste, the originals are gone.
    func clear() {
        content = nil
        AppServices.connections.closeUnused()
    }
}
