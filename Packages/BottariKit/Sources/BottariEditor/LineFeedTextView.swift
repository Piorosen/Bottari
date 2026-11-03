import AppKit

/// A plain-text view whose lines break with "\n" alone, as an opened file's
/// text does, so what it shows and counts is what will be saved: text pasted
/// or dropped with CRLF or CR line breaks comes in with "\n".
open class LineFeedTextView: NSTextView {
    /// Paste asks for plain text by its old name, NSStringPboardType.
    private static let plainText: Set<NSPasteboard.PasteboardType> = [.string, .init("NSStringPboardType")]

    open override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard Self.plainText.contains(type), let text = pasteboard.string(forType: type) else {
            return super.readSelection(from: pasteboard, type: type)
        }
        let lines = NSPasteboard.withUniqueName()
        defer { lines.releaseGlobally() }
        lines.declareTypes([.string], owner: nil)
        lines.setString(TextCodec.withLF(text), forType: .string)
        return super.readSelection(from: lines, type: .string)
    }
}
