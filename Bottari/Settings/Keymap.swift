import AppKit
import Observation
import SwiftUI

/// A key with modifiers, written the way macOS menus show it: "⇧⌘C", "F5", "Space".
nonisolated struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    /// A lowercase character, or one of the names in `names`.
    var key: String
    var control = false
    var option = false
    var shift = false
    var command = false

    private static let names: [(name: String, symbol: String, equivalent: Character)] = [
        ("space", "Space", " "), ("return", "↵", "\r"), ("tab", "Tab", "\t"), ("delete", "⌫", "\u{7F}"),
        ("forwarddelete", "⌦", "\u{F728}"), ("escape", "⎋", "\u{1B}"),
        ("up", "↑", "\u{F700}"), ("down", "↓", "\u{F701}"), ("left", "←", "\u{F702}"), ("right", "→", "\u{F703}"),
        ("home", "↖", "\u{F729}"), ("end", "↘", "\u{F72B}"), ("pageup", "⇞", "\u{F72C}"), ("pagedown", "⇟", "\u{F72D}"),
    ] + (1...12).map { ("f\($0)", "F\($0)", Character(UnicodeScalar(0xF703 + $0)!)) }

    init(_ key: String, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.key = key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    /// Parses `description`, e.g. "⇧⌘C".
    init?(parsing text: String) {
        var rest = Substring(text)
        var combo = KeyCombo("")
        while let first = rest.first, "⌃⌥⇧⌘".contains(first), rest.count > 1 {
            switch first {
            case "⌃": combo.control = true
            case "⌥": combo.option = true
            case "⇧": combo.shift = true
            default: combo.command = true
            }
            rest = rest.dropFirst()
        }
        if let named = Self.names.first(where: { $0.symbol == rest }) {
            combo.key = named.name
        } else if rest.count == 1 {
            combo.key = rest.lowercased()
        } else {
            return nil
        }
        self = combo
    }

    /// From a key press in a SwiftUI view.
    init(_ press: KeyPress) {
        self.init(character: press.key.character, modifiers: press.modifiers)
    }

    /// From a key event, for recording a new shortcut. Nil for modifier keys alone.
    init?(_ event: NSEvent) {
        guard let character = event.charactersIgnoringModifiers?.first else { return nil }
        let flags = event.modifierFlags
        var modifiers: EventModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        // The key on its own, not what Shift or Option make of it.
        let base = event.keyCode == 49 ? " " : character
        self.init(character: base, modifiers: modifiers)
    }

    private init(character: Character, modifiers: EventModifiers) {
        let key = Self.names.first { $0.equivalent == character }?.name
            ?? (character == "\u{8}" ? "delete" : character == "\u{3}" ? "return" : character.lowercased())
        self.init(key, control: modifiers.contains(.control), option: modifiers.contains(.option),
                  shift: modifiers.contains(.shift), command: modifiers.contains(.command))
    }

    var description: String {
        let symbol = Self.names.first { $0.name == key }?.symbol ?? key.uppercased()
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + symbol
    }

    var isFunctionKey: Bool { key.count > 1 && key.first == "f" && Int(key.dropFirst()) != nil }

    /// Menus take combos with ⌘ or ⌃, and function keys. A plain key there
    /// would also fire while typing in a text field, so the file list handles
    /// those itself.
    var belongsInMenu: Bool { command || control || isFunctionKey }

    var shortcut: KeyboardShortcut {
        let equivalent = Self.names.first { $0.name == key }?.equivalent ?? Character(key)
        var modifiers: EventModifiers = []
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        if command { modifiers.insert(.command) }
        return KeyboardShortcut(KeyEquivalent(equivalent), modifiers: modifiers)
    }
}

extension KeyCombo: Codable {
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let combo = KeyCombo(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: String(localized: "알 수 없는 키: \(text)")))
        }
        self = combo
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// What a shortcut can do to the files in the active pane.
enum PaneAction: String, CaseIterable, Identifiable, Sendable {
    case copyToOther, moveToOther, newFolder, rename, delete, preview, edit, bundle, switchPane, palette

    var id: Self { self }

    var title: String {
        switch self {
        case .copyToOther: String(localized: "반대편 패인에 복사")
        case .moveToOther: String(localized: "반대편 패인으로 이동")
        case .newFolder: String(localized: "새 폴더")
        case .rename: String(localized: "이름 바꾸기")
        case .delete: String(localized: "삭제 (휴지통)")
        case .preview: String(localized: "미리보기")
        case .edit: String(localized: "편집")
        case .bundle: String(localized: "보따리에 담기")
        case .switchPane: String(localized: "패인 전환")
        case .palette: String(localized: "명령 팔레트")
        }
    }
}

/// The two traditions a dual-pane file manager's keys come from.
enum KeyLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case finder, commander

    var id: Self { self }

    var title: String {
        switch self {
        case .finder: String(localized: "Finder식")
        case .commander: String(localized: "Commander식")
        }
    }

    var subtitle: String {
        switch self {
        case .finder: String(localized: "⌘ 조합 중심")
        case .commander: String(localized: "F5 복사, F6 이동, F7 새 폴더, F8 삭제")
        }
    }

    func combo(for action: PaneAction) -> KeyCombo {
        switch (self, action) {
        case (.finder, .copyToOther): KeyCombo("c", shift: true, command: true)
        case (.finder, .moveToOther): KeyCombo("x", shift: true, command: true)
        case (.finder, .newFolder): KeyCombo("n", shift: true, command: true)
        case (.finder, .rename): KeyCombo("return")
        case (.finder, .delete): KeyCombo("delete", command: true)
        case (.finder, .preview): KeyCombo("space")
        case (.finder, .edit): KeyCombo("e", command: true)
        case (.commander, .copyToOther): KeyCombo("f5")
        case (.commander, .moveToOther): KeyCombo("f6")
        case (.commander, .newFolder): KeyCombo("f7")
        case (.commander, .rename): KeyCombo("f2")
        case (.commander, .delete): KeyCombo("f8")
        case (.commander, .preview): KeyCombo("f3")
        case (.commander, .edit): KeyCombo("f4")
        case (_, .bundle): KeyCombo("b", command: true)
        case (_, .switchPane): KeyCombo("tab")
        case (_, .palette): KeyCombo("k", command: true)
        }
    }
}

/// The keys for pane actions: a layout, and whatever the user changed.
@Observable
final class Keymap {
    static let shared = Keymap()

    /// As kept in UserDefaults and in iCloud Drive's `keymap.json`.
    nonisolated struct Saved: Codable, Equatable, Sendable {
        var layout = KeyLayout.finder
        /// Action name → combo, only for keys the user changed.
        var custom: [String: KeyCombo] = [:]
    }

    private(set) var saved: Saved {
        didSet {
            guard saved != oldValue else { return }
            Self.refreshMenus()
            guard !AppDelegate.isRenderingSnapshots else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.key)
            settingsChanged()
        }
    }

    /// SwiftUI rebuilds menu items when a menu is about to open, and key
    /// equivalents are looked up without opening it; ask now, so a new key
    /// works straight away.
    private static func refreshMenus() {
        Task {
            await Task.yield()
            for item in NSApp.mainMenu?.items ?? [] {
                if let menu = item.submenu { menu.delegate?.menuNeedsUpdate?(menu) }
            }
        }
    }

    private static let key = "keymap"

    /// The app's own fixed shortcuts, so a new key that takes one is flagged.
    static let reserved: [KeyCombo: String] = [
        KeyCombo("c", command: true): String(localized: "복사 (클립보드)"), KeyCombo("v", command: true): String(localized: "붙여넣기"),
        KeyCombo("x", command: true): String(localized: "잘라내기"), KeyCombo("a", command: true): String(localized: "모두 선택"),
        KeyCombo("v", option: true, command: true): String(localized: "여기로 항목 이동"), KeyCombo("c", option: true, command: true): String(localized: "경로 복사"),
        KeyCombo("r", command: true): String(localized: "새로고침"), KeyCombo("[", command: true): String(localized: "뒤로"), KeyCombo("]", command: true): String(localized: "앞으로"),
        KeyCombo("up", command: true): String(localized: "상위 폴더"), KeyCombo("down", command: true): String(localized: "열기"), KeyCombo("`", control: true): String(localized: "SSH 터미널"),
        KeyCombo(",", command: true): String(localized: "설정"), KeyCombo("q", command: true): String(localized: "종료"), KeyCombo("w", command: true): String(localized: "창 닫기"),
        KeyCombo("n", command: true): String(localized: "새 창"), KeyCombo("delete"): String(localized: "뒤로"),
        KeyCombo("f", command: true): String(localized: "이 폴더에서 찾기"), KeyCombo("p", shift: true, command: true): String(localized: "미리보기 보기"),
        KeyCombo("o", option: true, command: true): String(localized: "반대편 패인에 이 폴더 열기"), KeyCombo("u", option: true, command: true): String(localized: "두 패인 바꾸기"),
    ]

    private init() {
        saved = AppDelegate.isRenderingSnapshots ? Saved() : UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    /// Switching the base layout keeps shortcuts the user set by hand; picking
    /// the layout already in use changes nothing.
    var layout: KeyLayout {
        get { saved.layout }
        set {
            guard newValue != saved.layout else { return }
            saved = Saved(layout: newValue, custom: saved.custom)
        }
    }

    func combo(for action: PaneAction) -> KeyCombo {
        saved.custom[action.rawValue] ?? saved.layout.combo(for: action)
    }

    func isCustom(_ action: PaneAction) -> Bool {
        saved.custom[action.rawValue] != nil
    }

    func set(_ combo: KeyCombo?, for action: PaneAction) {
        saved.custom[action.rawValue] = combo == saved.layout.combo(for: action) ? nil : combo
    }

    func replace(with saved: Saved) {
        self.saved = saved
    }

    /// For a menu item; nil when the combo is one the file list handles.
    func shortcut(for action: PaneAction) -> KeyboardShortcut? {
        let combo = combo(for: action)
        return combo.belongsInMenu ? combo.shortcut : nil
    }

    /// The action a plain key press in the file list stands for.
    func listAction(for combo: KeyCombo) -> PaneAction? {
        guard !combo.belongsInMenu else { return nil }
        return PaneAction.allCases.first { self.combo(for: $0) == combo }
    }

    /// What else uses `action`'s key, if anything.
    func clash(for action: PaneAction) -> String? {
        let combo = combo(for: action)
        if let other = PaneAction.allCases.first(where: { $0 != action && self.combo(for: $0) == combo }) {
            return other.title
        }
        return Self.reserved[combo]
    }
}
