import AppKit
import BottariSFTP
import Observation
import SwiftUI

/// How Bottari looks. Kept as JSON in the design's format, so a theme can be
/// passed around as a file:
///
///     { "name": "쪽빛 밤", "base": "dark",
///       "colors": { "background": "#0D1022", "panel": "#141A33", "line": "#2A3358", "text": "#E4E8F7", "accent": "#0F7C78" },
///       "density": "comfortable", "font": { "ui": "IBM Plex Sans KR", "mono": "JetBrains Mono" },
///       "tags": { "PROD": "#B93A0B" }, "list": { "showHidden": false } }
///
/// Anything left out (or a font that is not installed) falls back to macOS's own.
nonisolated struct Theme: Codable, Hashable, Identifiable, Sendable {
    enum Base: String, Codable, Sendable {
        case system, light, dark
    }

    enum Density: String, Codable, CaseIterable, Sendable {
        case comfortable, compact

        var title: String {
            switch self {
            case .comfortable: "편안하게"
            case .compact: "촘촘하게"
            }
        }
    }

    struct Colors: Codable, Hashable, Sendable {
        var background: String?
        var panel: String?
        var panel2: String?
        var line: String?
        var text: String?
        /// Nil follows the accent colour chosen in System Settings.
        var accent: String?
    }

    struct Fonts: Codable, Hashable, Sendable {
        /// Family names; nil means the system font. IBM Plex ships with the app.
        var ui: String? = "IBM Plex Sans KR"
        var mono: String? = "IBM Plex Mono"
    }

    struct ListOptions: Codable, Hashable, Sendable {
        /// Whether new panes show dotfiles.
        var showHidden = false
        /// Finder's colour icons instead of the design's line icons.
        var finderIcons = false

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            showHidden = try container.decodeIfPresent(Bool.self, forKey: .showHidden) ?? false
            finderIcons = try container.decodeIfPresent(Bool.self, forKey: .finderIcons) ?? false
        }
    }

    var id: String { name }
    var name: String
    var base = Base.system
    var colors = Colors()
    var density = Density.comfortable
    var font = Fonts()
    /// Tag label ("PROD", "STAGING", "DEV", "개인") → "#RRGGBB".
    var tags: [String: String] = [:]
    var list = ListOptions()

    init(name: String, base: Base = .system, colors: Colors = Colors()) {
        self.name = name
        self.base = base
        self.colors = colors
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "가져온 테마"
        base = try container.decodeIfPresent(Base.self, forKey: .base) ?? .system
        colors = try container.decodeIfPresent(Colors.self, forKey: .colors) ?? Colors()
        density = try container.decodeIfPresent(Density.self, forKey: .density) ?? .comfortable
        font = try container.decodeIfPresent(Fonts.self, forKey: .font) ?? Fonts()
        tags = try container.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
        list = try container.decodeIfPresent(ListOptions.self, forKey: .list) ?? ListOptions()
    }

    /// The design's colour sets. Choosing one keeps the accent, fonts and the rest.
    static let presets: [(theme: Theme, subtitle: String)] = [
        (Theme(name: "시스템"), "macOS 설정 따름"),
        (Theme(name: "종이", base: .light, colors: Colors(background: "#EFECE6", panel: "#FDFCFA", panel2: "#F5F2EC", line: "#E0DBD2", text: "#1C1A17")), "밝은 기본"),
        (Theme(name: "먹", base: .dark, colors: Colors(background: "#131211", panel: "#1B1A18", panel2: "#211F1C", line: "#2F2C28", text: "#ECE8E1")), "어두운 기본"),
        (Theme(name: "쪽빛 밤", base: .dark, colors: Colors(background: "#0D1022", panel: "#141A33", panel2: "#1A2140", line: "#2A3358", text: "#E4E8F7")), "푸른 어둠"),
        (Theme(name: "모시", base: .light, colors: Colors(background: "#EEEDEA", panel: "#FBFAF8", panel2: "#F4F3F0", line: "#DEDBD5", text: "#1C1B19")), "따뜻한 회색"),
        (Theme(name: "고대비", base: .light, colors: Colors(background: "#FFFFFF", panel: "#FFFFFF", panel2: "#F0F0F0", line: "#1A1A1A", text: "#000000")), "선명하게"),
    ]

    static let accents: [(name: String, hex: String)] = [
        ("쪽빛", "#2D5A8C"), ("청록", "#0F7C78"), ("자주", "#8A3FA0"), ("송진", "#9A6700"), ("진달래", "#B0306A"), ("먹", "#2B2F38"),
    ]

    /// Choices per tag; the first is the default.
    static let tagChoices: [(tag: SavedSite.Tag, hexes: [String])] = [
        (.prod, ["#B93A0B", "#B42318", "#9A3412"]),
        (.staging, ["#8A6100", "#9A6700", "#7C5E10"]),
        (.dev, ["#0D7068", "#2F6F3E", "#1D5FA8"]),
    ]

    /// Which preset's colours these are, if any.
    var presetName: String? {
        Self.presets.first { $0.theme.base == base && $0.theme.colors.withoutAccent == colors.withoutAccent }?.theme.name
    }
}

nonisolated extension Theme.Colors {
    var withoutAccent: Theme.Colors {
        var copy = self
        copy.accent = nil
        return copy
    }
}

/// The theme in use and the theme files the user keeps, in
/// `~/Library/Application Support/Bottari/themes/`.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var current: Theme {
        didSet {
            guard current != oldValue else { return }
            save()
            applyAppearance()
        }
    }

    /// Theme files, by name.
    private(set) var saved: [Theme] = []

    @ObservationIgnored let folder = URL.applicationSupportDirectory.appending(path: "Bottari/themes", directoryHint: .isDirectory)
    @ObservationIgnored private let file = URL.applicationSupportDirectory.appending(path: "Bottari/theme.json")

    private init() {
        // Snapshots draw the default look and leave the user's files alone.
        current = AppDelegate.isRenderingSnapshots ? Theme.presets[0].theme
            : (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Theme.self, from: $0) } ?? Theme.presets[0].theme
        if !AppDelegate.isRenderingSnapshots { reloadSaved() }
    }

    // MARK: - Choosing

    /// A preset's colours, keeping the accent, fonts and the rest.
    func choose(preset: Theme) {
        var theme = current
        theme.base = preset.base
        theme.colors = Theme.Colors(
            background: preset.colors.background, panel: preset.colors.panel, panel2: preset.colors.panel2,
            line: preset.colors.line, text: preset.colors.text, accent: current.colors.accent
        )
        theme.name = preset.name
        current = theme
    }

    /// Light and dark follow the theme in every window.
    func applyAppearance() {
        NSApp?.appearance = switch current.base {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Colours and fonts

    var accent: Color {
        current.colors.accent.flatMap { Color(themeHex: $0, liftedInDark: true) } ?? .accentColor
    }

    func tagColor(_ tag: SavedSite.Tag) -> Color? {
        current.tags[tag.label].flatMap { Color(themeHex: $0, liftedInDark: true) }
    }

    /// Nil when the system font is in use, so views keep their own text styles.
    var uiFontFamily: String? { Self.installed(current.font.ui) }
    var monoFontFamily: String? { Self.installed(current.font.mono) }

    func mono(_ style: Font.TextStyle) -> Font {
        guard let family = monoFontFamily else { return .system(style, design: .monospaced) }
        return .custom(family, size: Self.pointSize(style), relativeTo: style)
    }

    func monoNSFont(size: CGFloat) -> NSFont {
        monoFontFamily.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Extra space above and below each file row.
    var rowPadding: CGFloat { current.density == .compact ? 0 : 3 }

    /// Font families worth offering that are installed on this Mac.
    static let uiFontChoices = available([BundledFonts.sans, "Pretendard", "Noto Sans KR", "Spoqa Han Sans Neo", "Apple SD Gothic Neo"])
    static let monoFontChoices = available([BundledFonts.mono, "JetBrains Mono", "IBM Plex Mono", "D2Coding", "Fira Code", "Menlo", "Monaco"])

    private static func available(_ families: [String]) -> [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        var seen = Set<String>()
        return families.filter { installed.contains($0) && seen.insert($0).inserted }
    }

    private static func installed(_ family: String?) -> String? {
        guard let family, NSFontManager.shared.availableFontFamilies.contains(family) else { return nil }
        return family
    }

    static func pointSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        default: 10
        }
    }

    // MARK: - Files

    func reloadSaved() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        saved = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Theme.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Writes the current theme to `url`, named after the file. In the themes
    /// folder it joins the saved themes.
    func export(to url: URL) throws {
        var theme = current
        theme.name = url.deletingPathExtension().lastPathComponent
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(theme).write(to: url, options: .atomic)
        current = theme
        reloadSaved()
        settingsChanged()
    }

    /// Reads a theme file from anywhere, keeps a copy in the themes folder and uses it.
    func importTheme(from url: URL) throws {
        let theme = try JSONDecoder().decode(Theme.self, from: Data(contentsOf: url))
        _ = try write(theme)
        current = theme
        reloadSaved()
        settingsChanged()
    }

    func delete(_ theme: Theme) {
        try? FileManager.default.removeItem(at: fileURL(for: theme))
        reloadSaved()
        settingsChanged()
    }

    /// The theme files as another Mac left them.
    func replaceSaved(with themes: [Theme]) {
        let keep = Set(themes.map(\.name))
        for theme in saved where !keep.contains(theme.name) {
            try? FileManager.default.removeItem(at: fileURL(for: theme))
        }
        for theme in themes where !saved.contains(theme) {
            _ = try? write(theme)
        }
        reloadSaved()
    }

    func fileURL(for theme: Theme) -> URL {
        folder.appending(path: theme.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".json")
    }

    private func write(_ theme: Theme) throws -> URL {
        let url = fileURL(for: theme)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(theme).write(to: url, options: .atomic)
        return url
    }

    private func save() {
        guard !AppDelegate.isRenderingSnapshots else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.encoder.encode(current).write(to: file, options: .atomic)
        settingsChanged()
    }

    var json: String {
        (try? Self.encoder.encode(current)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

extension Font {
    /// The theme's monospaced font, for paths, sizes and code.
    static func themeMono(_ style: Font.TextStyle) -> Font {
        ThemeStore.shared.mono(style)
    }
}

extension Color {
    /// The theme's accent, or the system's when the theme has none.
    static var themeAccent: Color { ThemeStore.shared.accent }

    /// A colour from "#RRGGBB". `liftedInDark` lightens it a little in dark
    /// mode, the way macOS lightens its own accents there.
    init?(themeHex hex: String, liftedInDark: Bool = false) {
        guard let color = NSColor(themeHex: hex) else { return nil }
        if !liftedInDark {
            self.init(nsColor: color)
        } else {
            self.init(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color.blended(withFraction: 0.35, of: .white) ?? color : color
            })
        }
    }
}

extension NSColor {
    convenience init?(themeHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// "#RRGGBB" in sRGB.
    var themeHex: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded())
        )
    }
}

extension Notification.Name {
    /// Something the iCloud sync carries changed on this Mac.
    static let settingsChanged = Notification.Name("BottariSettingsChanged")
}

/// Tells the iCloud sync that something it carries changed.
func settingsChanged() {
    NotificationCenter.default.post(name: .settingsChanged, object: nil)
}

/// The theme's accent, colours and UI font for a window's content.
struct ThemedWindow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(ThemeStore.shared.accent)
            .foregroundStyle(Palette.text)
            .font(.ui(.body))
    }
}

extension View {
    func themed() -> some View {
        modifier(ThemedWindow())
    }
}
