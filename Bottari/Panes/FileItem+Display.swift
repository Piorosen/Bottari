import BottariCore
import BottariSFTP
import Foundation
import SwiftUI

extension FileItem {
    /// "4.2 KB", "512 B", "1.2 GB": decimal units, as Finder counts them.
    var formattedSize: String {
        guard let size, !isDirectory else { return "—" }
        return ByteFormat.string(size)
    }

    /// "10/21 18:40" this year, "2025/03/01" before.
    var shortModified: String {
        guard let modified else { return "—" }
        let sameYear = Calendar.current.isDate(modified, equalTo: .now, toGranularity: .year)
        return (sameYear ? Self.thisYear : Self.otherYears).string(from: modified)
    }

    /// "2026/10/22 14:02"
    var formattedModified: String {
        guard let modified else { return "—" }
        return Self.full.string(from: modified)
    }

    private static let thisYear = formatter("MM/dd HH:mm")
    private static let otherYears = formatter("yyyy/MM/dd")
    private static let full = formatter("yyyy/MM/dd HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// Keys, passwords and the like: worth a "비밀값" badge before copying them around.
    var looksSecret: Bool {
        let name = name.lowercased()
        return !isDirectory && (name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env")
            || ["pem", "key", "p12", "pfx", "keystore", "jks"].contains(path.pathExtension.lowercased())
            || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa"))
    }

    private static let archiveExtensions: Set<String> = ["zip", "gz", "tgz", "tar", "bz2", "xz", "zst", "7z", "rar", "dmg", "iso"]

    /// A line icon for the design's file lists.
    var glyph: String {
        if isDirectory { return "folder" }
        if isSymbolicLink { return "arrowshape.turn.up.right" }
        if looksSecret { return "key" }
        if Self.archiveExtensions.contains(path.pathExtension.lowercased()) { return "archivebox" }
        return switch FileKind(self) {
        case .image: "photo"
        case .video: "film"
        case .text: "doc.text"
        case .other: "doc"
        }
    }
}

nonisolated enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        let rounded = (value * 10).rounded() / 10
        let number = rounded >= 100 || rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(number) \(units[unit])"
    }

    /// "48 MB/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        string(Int64(bytesPerSecond)) + "/s"
    }
}

/// The line icon of a file, or Finder's own when the theme asks for it.
struct FileGlyph: View {
    let item: FileItem
    let isLocal: Bool
    var size: CGFloat = 15

    var body: some View {
        Group {
            if ThemeStore.shared.current.list.finderIcons {
                FileIcon.image(for: item, isLocal: isLocal)
                    .resizable()
                    .frame(width: size + 1, height: size + 1)
            } else {
                Image(systemName: item.glyph)
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(item.isDirectory ? AnyShapeStyle(Color.themeAccent) : AnyShapeStyle(.secondary))
                    .frame(width: size + 2, height: size)
            }
        }
        .accessibilityLabel(item.isSymbolicLink ? String(localized: "링크") : item.isDirectory ? String(localized: "폴더") : String(localized: "파일"))
    }
}

extension FileProvider {
    /// "SFTP", "S3", "Drive": the small mono caption beside a pane's name.
    var kindLabel: String {
        if self is SFTPFileProvider { return "SFTP" }
        if isLocal { return "Mac" }
        let type = String(describing: Swift.type(of: self))
        if type.contains("S3") { return "S3" }
        if type.contains("Drive") { return "Drive" }
        return ""
    }

    /// A `Glyph` name.
    var symbol: String {
        if self is SFTPFileProvider { return "bt.server" }
        if isLocal { return "bt.mac" }
        let type = String(describing: Swift.type(of: self))
        if type.contains("S3") { return "bt.bucket" }
        if type.contains("Drive") { return "bt.cloud" }
        return "externaldrive"
    }
}
