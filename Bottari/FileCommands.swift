import AppKit
import BottariTransfer
import SwiftUI

/// The Edit menu's copy, paste and select all act on files when a pane has
/// focus, and on text everywhere else (the connection manager's fields).
struct FileCommands: Commands {
    @FocusedValue(\.paneFocus) private var focus

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("새 폴더") {
                if let focus { focus.workspace.makeFolder(in: focus.side) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(focus == nil)
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
            Button("경로 복사") {
                if let focus { focus.workspace.copyPaths(from: focus.side) }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(focus?.pane.selection.isEmpty ?? true)
            // Disabled outside panes, so text fields keep ⌘⌫ for themselves.
            Button(focus?.pane.provider.capabilities.contains(.trash) == false ? "삭제…" : "휴지통으로 이동") {
                if let focus { focus.workspace.delete(focus.pane.selectedItems, in: focus.side) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(focus?.pane.selection.isEmpty ?? true)
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
                    run { pane in
                        if pane.selectedItems.count == 1, let item = pane.selectedItems.first {
                            await pane.activate(item)
                        }
                    }
                }
                .keyboardShortcut(.downArrow)
                Divider()
                Button("새로고침") { run { await $0.reload() } }
                    .keyboardShortcut("r")
            }
            .disabled(focus == nil)
        }
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
