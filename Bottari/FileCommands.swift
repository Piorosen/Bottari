import AppKit
import BottariTransfer
import SwiftUI

/// The Edit menu's copy, paste and select all act on files when a pane has
/// focus, and on text everywhere else (the connection manager's fields).
struct FileCommands: Commands {
    @FocusedValue(\.paneFocus) private var focus

    var body: some Commands {
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
        }
    }

    private var pasteTitle: String {
        guard focus != nil, let count = AppServices.clipboard.content?.items.count else { return "붙여넣기" }
        return "붙여넣기 (\(count)개)"
    }

    private func sendToTextField(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
