import AppKit
import BottariSFTP
import SwiftUI

extension SavedSite.Tag {
    var label: String {
        switch self {
        case .prod: "PROD"
        case .staging: "STAGING"
        case .dev: "DEV"
        case .personal: String(localized: "개인")
        }
    }

    /// The theme's colour for the tag, or the design's own, lighter in dark
    /// mode so they stay readable.
    var color: Color {
        ThemeStore.shared.tagColor(self) ?? defaultColor
    }

    var defaultColor: Color {
        switch self {
        case .prod: Color(light: 0xB93A0B, dark: 0xF2874E)
        case .staging: Color(light: 0x8A6100, dark: 0xE0B44C)
        case .dev: Color(light: 0x0D7068, dark: 0x3CC4B4)
        case .personal: Color(light: 0x7A3FB0, dark: 0xC39BEA)
        }
    }
}

extension SavedSite {
    /// `user@host:port via jump` (or the bucket, or the Google account), as the site list shows it.
    var summary: String {
        switch kind {
        case .s3(let settings): return "s3://\(settings.bucket)"
        case .googleDrive(let settings): return settings.account.isEmpty ? String(localized: "로그인 필요") : settings.account
        case .sftp: break
        }
        var text = "\(endpoint.username)@\(endpoint.host)"
        if endpoint.port != 22 { text += ":\(endpoint.port)" }
        if !proxyJump.isEmpty { text += " via \(proxyJump.joined(separator: ", "))" }
        return text
    }

    /// A `Glyph` name.
    var symbol: String {
        switch kind {
        case .sftp: "bt.server"
        case .s3: "bt.bucket"
        case .googleDrive: "bt.cloud"
        }
    }
}

/// A small coloured capsule with the tag's name.
struct TagChip: View {
    let tag: SavedSite.Tag

    var body: some View {
        Text(tag.label)
            .font(.ui(.caption2, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(tag == .prod ? .white : tag.color)
            .background(tag == .prod ? tag.color : tag.color.opacity(0.14), in: .rect(cornerRadius: 3))
            .accessibilityLabel("\(tag.label) 서버")
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
