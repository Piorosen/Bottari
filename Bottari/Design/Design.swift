import AppKit
import BottariSFTP
import CoreText
import SwiftUI

/// IBM Plex, the design's typeface, ships inside the app (SIL Open Font License).
nonisolated enum BundledFonts {
    static let sans = "IBM Plex Sans KR"
    static let mono = "IBM Plex Mono"

    static func register() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
}

/// How table rows look in the design: no lines between them, and a faint
/// accent behind the selected one with the text left as it is. AppKit has no
/// switch for either, so the row view's drawing methods are replaced.
enum TableRowLook {
    private static var done: Set<String> = []

    /// For every table and list in the app.
    static func hideSeparators(in rowClass: AnyClass = NSTableRowView.self) {
        replace(#selector(NSTableRowView.drawSeparator(in:)), in: rowClass, with: { (_: NSTableRowView, _: NSRect) in } as @convention(block) (NSTableRowView, NSRect) -> Void)
    }

    /// For the file lists' row class only.
    static func useFaintSelection(in rowClass: AnyClass) {
        replace(#selector(NSTableRowView.drawSelection(in:)), in: rowClass, with: { (row: NSTableRowView, _: NSRect) in
            let color = MainActor.assumeIsolated { NSColor(Color.themeAccent) }
            let focused = row.window?.isKeyWindow == true
            color.withAlphaComponent(focused ? 0.16 : 0.09).setFill()
            NSBezierPath(roundedRect: row.bounds.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
        } as @convention(block) (NSTableRowView, NSRect) -> Void)
        // Unemphasized rows keep their text colours instead of turning white.
        replace(#selector(getter: NSTableRowView.isEmphasized), in: rowClass, with: { (_: NSTableRowView) -> Bool in false } as @convention(block) (NSTableRowView) -> Bool)
    }

    private static func replace(_ selector: Selector, in rowClass: AnyClass, with block: Any) {
        guard done.insert("\(NSStringFromClass(rowClass)).\(NSStringFromSelector(selector))").inserted,
              let method = class_getInstanceMethod(rowClass, selector) else { return }
        let implementation = imp_implementationWithBlock(block)
        // A subclass that only inherits the method gets its own; one that overrides it is replaced.
        if !class_addMethod(rowClass, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}

/// The design's colours: the theme's own, or 종이 in light mode and 먹 in dark.
enum Palette {
    private static var colors: Theme.Colors { ThemeStore.shared.current.colors }

    /// Behind the cards.
    static var background: Color { custom(colors.background) ?? Color(light: 0xECEEF2, dark: 0x0E1014) }
    /// Cards: panes, panels, the sidebar's bundle.
    static var panel: Color { custom(colors.panel) ?? Color(light: 0xFFFFFF, dark: 0x15181E) }
    /// Headers and wells inside cards.
    static var panel2: Color { custom(colors.panel2) ?? Color(light: 0xF6F7F9, dark: 0x1A1E25) }
    static var line: Color { custom(colors.line) ?? Color(light: 0xDCE0E6, dark: 0x272C35) }
    static var text: Color { custom(colors.text) ?? Color(light: 0x14171D, dark: 0xE6E8EC) }
    /// The accent, faint: selected rows and chosen options.
    static var selection: Color { Color.themeAccent.opacity(0.13) }

    private static func custom(_ hex: String?) -> Color? {
        hex.flatMap { Color(themeHex: $0) }
    }
}

extension Font {
    /// The theme's UI font (IBM Plex Sans KR unless changed) at a text style's size.
    static func ui(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let weight = weight ?? (style == .headline ? .semibold : nil)
        guard let family = ThemeStore.shared.uiFontFamily else {
            let font = Font.system(style)
            return weight.map { font.weight($0) } ?? font
        }
        let font = Font.custom(family, size: ThemeStore.pointSize(style), relativeTo: style)
        return weight.map { font.weight($0) } ?? font
    }
}

// MARK: - Cards

extension View {
    /// A white (or the theme's) card with a hairline border; `highlighted`
    /// draws the accent border of the active pane.
    func card(highlighted: Bool = false, radius: CGFloat = 10) -> some View {
        background(Palette.panel, in: .rect(cornerRadius: radius))
            .clipShape(.rect(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(highlighted ? Color.themeAccent : Palette.line, lineWidth: highlighted ? 2 : 1)
            )
    }

    /// A tinted well inside a card.
    func well(radius: CGFloat = 8) -> some View {
        background(Palette.panel2, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Palette.line))
    }
}

/// The small grey heading over a group: "서버", "클라우드".
struct SectionLabel: View {
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(.ui(.caption, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

/// `prod-web`, monospaced in a bordered box, as in route chips and file sources.
struct MonoChip: View {
    let text: String
    var dashed = false
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.themeMono(.caption))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(dashed ? AnyShapeStyle(.secondary) : highlighted ? AnyShapeStyle(Color.themeAccent) : AnyShapeStyle(.primary))
            .background(dashed ? Color.clear : highlighted ? Palette.selection : Palette.panel2, in: .rect(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(highlighted ? Color.themeAccent.opacity(0.6) : Palette.line, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
            )
    }
}

/// A word in a small rounded box: "비밀값", "추천", "Google 문서".
struct Badge: View {
    let text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.ui(.caption2, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .background((color ?? .secondary).opacity(0.1), in: .rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder((color ?? .secondary).opacity(0.35)))
    }
}

/// A status light: filled when connected, hollow when not.
struct StatusDot: View {
    let on: Bool
    var color: Color = Color(light: 0x0F7C5A, dark: 0x3CC48E)

    var body: some View {
        Circle()
            .fill(on ? color : .clear)
            .overlay(Circle().strokeBorder(on ? color : Color.secondary, lineWidth: 1.2))
            .frame(width: 7, height: 7)
    }
}

/// A square bordered button with a symbol, as in the pane headers and toolbar.
struct IconButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(.callout))
            .frame(minWidth: 26, minHeight: 24)
            .padding(.horizontal, 2)
            .foregroundStyle(isOn ? AnyShapeStyle(Color.themeAccent) : AnyShapeStyle(.primary))
            .background(isOn ? Palette.selection : configuration.isPressed ? Palette.panel2 : Palette.panel, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
            .contentShape(.rect)
    }
}

/// The outlined buttons of the design: white with a hairline, or filled with
/// the accent for the main action.
struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    var dashed = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(.callout, weight: prominent ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
            .background(prominent ? Color.themeAccent : configuration.isPressed ? Palette.panel2 : Palette.panel, in: .rect(cornerRadius: 7))
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(destructive ? Color.red.opacity(0.5) : Palette.line, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(.rect)
    }
}

/// A label above its field, and a hint below, as in the design's forms.
struct LabeledField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let content: Content

    init(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.ui(.callout, weight: .semibold))
            content
            if let hint {
                Text(hint)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// A text field drawn as the design's white box with a hairline.
    func designField(mono: Bool = false) -> some View {
        textFieldStyle(.plain)
            .font(mono ? .themeMono(.body) : .ui(.body))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.panel, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
    }
}

/// A setting that switches on and off, with what it does underneath.
struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(.body, weight: .medium))
                if let detail {
                    Text(detail).font(.ui(.caption)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(12)
        .background(Palette.panel, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
    }
}

/// "‹ 메인으로" at the top left of the secondary windows.
struct BackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left")
                .font(.ui(.callout))
        }
        .help("이 창 닫기")
    }
}

/// The title and grey subtitle beside the back button.
struct WindowHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.ui(.title3, weight: .bold))
            if let subtitle {
                Text(subtitle).font(.ui(.callout)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Tag chips as the design draws them: PROD filled, the others outlined.
extension TagChip {
    static func outlined(_ tag: SavedSite.Tag) -> some View {
        Text(tag.label)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(tag.color)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tag.color, lineWidth: 1))
    }
}
