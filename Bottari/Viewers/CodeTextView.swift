import AppKit
import BottariEditor
import SwiftUI

/// An NSTextView with syntax colouring, line numbers and the find bar.
/// Typing flows out through `text`; the model replaces the whole text (after
/// loading or merging) by bumping `revision`.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    let revision: Int
    let language: String?
    let isEditable: Bool
    var onEdit: () -> Void = {}
    var onCursorMove: (_ line: Int, _ column: Int) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let storage = SyntaxHighlighting.makeStorage(language: language, dark: dark, font: ThemeStore.shared.monoNSFont(size: 13))
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = ThemedTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = ThemeStore.shared.monoNSFont(size: 13)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = isEditable

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: scrollView)
        context.coordinator.revision = revision
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            textView.string = text
            scrollView.verticalRulerView?.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        var revision = 0

        init(_ parent: CodeTextView) {
            self.parent = parent
        }

        /// Line numbers follow the text as it scrolls.
        func observeScrolling(of scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak scrollView] _ in
                MainActor.assumeIsolated {
                    scrollView?.verticalRulerView?.needsDisplay = true
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onEdit()
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let string = textView.string as NSString
            let location = min(textView.selectedRange().location, string.length)
            let before = string.substring(to: location)
            let line = before.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let column = location - (before as NSString).range(of: "\n", options: .backwards).upperBound + 1
            parent.onCursorMove(line, before.contains("\n") ? column : location + 1)
        }
    }
}

/// Switches the colour theme when the appearance changes.
private final class ThemedTextView: NSTextView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let storage = textStorage else { return }
        SyntaxHighlighting.apply(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, font: ThemeStore.shared.monoNSFont(size: 13), to: storage)
    }
}

/// Line numbers beside the text, for matching errors like "nginx.conf:12".
private final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var countedText = ""

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let string = textView.string as NSString
        if countedText != textView.string {
            countedText = textView.string
            lineStarts = [0]
            var index = 0
            while index < string.length {
                let range = string.range(of: "\n", range: NSRange(location: index, length: string.length - index))
                guard range.location != NSNotFound else { break }
                lineStarts.append(range.location + 1)
                index = range.location + 1
            }
        }
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        // The first visible line, by binary search over line starts.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= characters.location { low = middle } else { high = middle - 1 }
        }
        var line = low
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let start = lineStarts[line]
            let y: CGFloat
            if start >= string.length {
                y = layoutManager.extraLineFragmentRect.minY
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                y = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let origin = convert(NSPoint(x: 0, y: y + textView.textContainerInset.height), from: textView)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: origin.y + 2), withAttributes: attributes)
            line += 1
        }
    }
}
