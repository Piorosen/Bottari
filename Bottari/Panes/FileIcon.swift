import AppKit
import BottariCore
import SwiftUI
import UniformTypeIdentifiers

/// Finder-looking icons. Local files ask Finder directly, so custom folder icons
/// show up; remote files get the generic icon for their type.
enum FileIcon {
    private static var typeIcons: [String: NSImage] = [:]

    static func image(for item: FileItem, isLocal: Bool) -> Image {
        Image(nsImage: nsImage(for: item, isLocal: isLocal))
    }

    private static func nsImage(for item: FileItem, isLocal: Bool) -> NSImage {
        if isLocal {
            return NSWorkspace.shared.icon(forFile: item.path.string)
        }
        let key = item.isDirectory ? "/" : item.path.pathExtension.lowercased()
        if let cached = typeIcons[key] {
            return cached
        }
        let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: key) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        typeIcons[key] = icon
        return icon
    }
}
