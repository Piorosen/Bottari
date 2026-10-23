import AppKit
import BottariCore
import SwiftUI
import UniformTypeIdentifiers

/// Finder-looking icons. Local files ask Finder directly, so custom folder icons
/// show up; remote files get the generic icon for their type.
///
/// Finder reads inside a folder to find its icon, so privacy-guarded folders and
/// links into them get stock icons instead: otherwise just listing the home
/// folder would make macOS ask for Desktop, Documents and Downloads access.
enum FileIcon {
    private static var typeIcons: [String: NSImage] = [:]
    private static var stockIcons: [String: NSImage] = [:]
    private static let privacy = PrivacyGuard()

    static func image(for item: FileItem, isLocal: Bool) -> Image {
        Image(nsImage: nsImage(for: item, isLocal: isLocal))
    }

    private static func nsImage(for item: FileItem, isLocal: Bool) -> NSImage {
        if isLocal {
            if item.isSymbolicLink, item.kind == .other {
                return typeIcon(for: .symbolicLink, key: "@link")
            }
            if item.isDirectory, privacy.isGuardedFolder(item.path) {
                return guardedFolderIcon(item.path)
            }
            return NSWorkspace.shared.icon(forFile: item.path.string)
        }
        let key = item.isDirectory ? "/" : item.path.pathExtension.lowercased()
        return typeIcon(for: item.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data), key: key)
    }

    private static func typeIcon(for type: UTType, key: String) -> NSImage {
        if let cached = typeIcons[key] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(for: type)
        typeIcons[key] = icon
        return icon
    }

    /// The system's own Desktop, Documents and Downloads icons, without looking inside.
    private static func guardedFolderIcon(_ path: RemotePath) -> NSImage {
        let file = switch path.name {
        case "Desktop": "DesktopFolderIcon"
        case "Documents": "DocumentsFolderIcon"
        case "Downloads": "DownloadsFolder"
        default: "GenericFolderIcon"
        }
        if let cached = stockIcons[file] {
            return cached
        }
        let icon = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(file).icns")
            ?? NSWorkspace.shared.icon(for: .folder)
        stockIcons[file] = icon
        return icon
    }
}
