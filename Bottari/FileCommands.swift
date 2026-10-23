import AppKit
import BottariSFTP
import BottariTransfer
import SwiftUI

/// The Edit menu's copy, paste and select all act on files when a pane has
/// focus, and on text everywhere else (the connection manager's fields).
struct FileCommands: Commands {
    @FocusedValue(\.paneFocus) private var focus

    var body: some Commands {
        // Keys come from the keymap (Settings › 단축키); plain keys such as
        // Space are left to the file list, so they still type in text fields.
        CommandGroup(after: .newItem) {
            action(.newFolder, "새 폴더", needsSelection: false)
            Divider()
            action(.copyToOther, "반대편 패인에 복사")
            action(.moveToOther, "반대편 패인으로 이동")
            action(.rename, "이름 바꾸기")
            action(.preview, "빠른 미리보기")
            action(.edit, "편집기로 열기")
        }
        CommandGroup(replacing: .pasteboard) {
            Button("잘라내기") { sendToTextField(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x")
                .disabled(focus != nil)
            Button("복사") {
                if let focus {
                    focus.workspace.copyToClipboard(from: focus.side)
                } else {
                    sendToTextField(#selector(NSText.copy(_:)))
                }
            }
            .keyboardShortcut("c")
            Button(pasteTitle) {
                if let focus {
                    focus.workspace.paste(into: focus.side, kind: .copy)
                } else {
                    sendToTextField(#selector(NSText.paste(_:)))
                }
            }
            .keyboardShortcut("v")
            Button("이동해서 붙여넣기") {
                if let focus {
                    focus.workspace.paste(into: focus.side, kind: .move)
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(focus == nil || AppServices.clipboard.content == nil)
            Button("모두 선택") {
                if let focus {
                    focus.pane.selectAll()
                } else {
                    sendToTextField(#selector(NSText.selectAll(_:)))
                }
            }
            .keyboardShortcut("a")
            Divider()
            action(.bundle, "보따리에 담기")
            Button("경로 복사") {
                if let focus { focus.workspace.copyPaths(from: focus.side) }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(focus?.pane.selection.isEmpty ?? true)
            // Disabled outside panes, so text fields keep ⌘⌫ for themselves.
            action(.delete, focus?.pane.provider.capabilities.contains(.trash) == false ? "삭제…" : "휴지통으로 이동")
        }
        CommandMenu("이동") {
            // Disabled outside panes, so text fields keep ⌘↑ and ⌘↓ for themselves.
            Group {
                Button("뒤로") { run { await $0.goBack() } }
                    .keyboardShortcut("[")
                Button("앞으로") { run { await $0.goForward() } }
                    .keyboardShortcut("]")
                Button("상위 폴더") { run { await $0.goUp() } }
                    .keyboardShortcut(.upArrow)
                Button("열기") {
                    if let focus, focus.pane.selectedItems.count == 1, let item = focus.pane.selectedItems.first {
                        focus.workspace.open(item, in: focus.side)
                    }
                }
                .keyboardShortcut(.downArrow)
                Divider()
                Button("새로고침") { run { await $0.reload() } }
                    .keyboardShortcut("r")
                Divider()
                Button("SSH 터미널") {
                    if let focus { focus.workspace.openTerminal(in: focus.side) }
                }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(!(focus?.pane.provider is SFTPFileProvider))
            }
            .disabled(focus == nil)
        }
    }

    /// A menu item for a keymap action on the focused pane.
    private func action(_ action: PaneAction, _ title: String, needsSelection: Bool = true) -> some View {
        Button(title) {
            if let focus { focus.workspace.perform(action, in: focus.side) }
        }
        .keyboardShortcut(Keymap.shared.shortcut(for: action))
        .disabled(focus == nil || (needsSelection && focus?.pane.selection.isEmpty != false))
    }

    private func run(_ action: @escaping (PaneModel) async -> Void) {
        guard let pane = focus?.pane else { return }
        Task { await action(pane) }
    }

    private var pasteTitle: String {
        guard focus != nil, let count = AppServices.clipboard.content?.items.count else { return "붙여넣기" }
        return "붙여넣기 (\(count)개)"
    }

    private func sendToTextField(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
