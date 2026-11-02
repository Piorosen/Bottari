import AppKit

extension NSTextView {
    /// Takes `text` in place of everything, as after loading or merging.
    /// Edits made to the old text can no longer be undone: their ranges
    /// point into text that is gone.
    public func replaceAllText(with text: String) {
        string = text
        if let textStorage {
            undoManager?.removeAllActions(withTarget: textStorage)
        }
    }
}
