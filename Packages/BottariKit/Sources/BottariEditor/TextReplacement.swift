import AppKit

extension NSTextView {
    /// Takes `text` in place of everything, as after loading or merging.
    public func replaceAllText(with text: String) {
        string = text
    }
}
