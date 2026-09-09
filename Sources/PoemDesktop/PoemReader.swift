import AppKit
import PoemCore

/// An optional comfortable reading view for unusually large poems. The desktop
/// still shows the complete composition; this window preserves the same lines.
@MainActor
final class PoemReader {
    struct Diagnostics {
        let body: String
        let bodyFontSize: CGFloat
        let bodyFontName: String
        let allCharactersLaidOut: Bool
        let sourceLineCount: Int
        let renderedLineCount: Int
    }
    private let window: NSWindow
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var bodyRange = NSRange(location: 0, length: 0)
    private var expectedLineCount = 0

    init() {
        let available = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 850)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1000, available.width - 100),
                                             height: min(760, available.height - 100)),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Read Poem"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        window.center()
        let paper = NSColor(calibratedRed: 0.985, green: 0.975, blue: 0.945, alpha: 1)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = paper
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.autoresizingMask = []
        textView.textContainerInset = NSSize(width: 30, height: 26)
        textView.drawsBackground = true
        textView.backgroundColor = paper
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        scrollView.documentView = textView
        window.contentView = scrollView
    }

    func show(_ poem: Poem, typeface: PoemTypeface = .georgia) {
        prepare(poem, typeface: typeface)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func prepare(_ poem: Poem, typeface: PoemTypeface = .georgia) {
        window.title = poem.title
        let bodyFont = typeface.font(size: 21)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 3
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: NSColor.black, .paragraphStyle: paragraph
        ]
        let content = NSMutableAttributedString(string: poem.title + "\n", attributes: [
            .font: typeface.font(size: 28),
            .foregroundColor: NSColor.black, .paragraphStyle: paragraph
        ])
        content.append(NSAttributedString(string: poem.author + "\n\n", attributes: [
            .font: typeface.font(size: 17, italic: true),
            .foregroundColor: NSColor.black, .paragraphStyle: paragraph
        ]))
        bodyRange = NSRange(location: content.length, length: (poem.body as NSString).length)
        expectedLineCount = content.string.components(separatedBy: "\n").count + poem.body.components(separatedBy: "\n").count - 1
        content.append(NSAttributedString(string: poem.body, attributes: bodyAttributes))
        let measured = content.size()
        // Give the text container its complete natural width; the horizontal
        // scroller handles prose-sized lines without inserting new line breaks.
        let width = max(scrollView.contentSize.width, ceil(measured.width) + 64)
        textView.textContainer?.containerSize = NSSize(width: width - 60, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(content)
        let used: NSRect
        if let container = textView.textContainer, let manager = textView.layoutManager {
            manager.ensureLayout(for: container)
            used = manager.usedRect(for: container)
        } else { used = NSRect(origin: .zero, size: measured) }
        let height = max(scrollView.contentSize.height, ceil(used.height) + 56)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.textContainer?.containerSize = NSSize(width: width - 60, height: height - 52)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var diagnostics: Diagnostics {
        guard let storage = textView.textStorage, let manager = textView.layoutManager,
              let container = textView.textContainer else {
            return Diagnostics(body: "", bodyFontSize: 0, bodyFontName: "", allCharactersLaidOut: false,
                               sourceLineCount: 0, renderedLineCount: 0)
        }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(for: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var fragments = 0
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in fragments += 1 }
        // AppKit keeps an extra trailing empty line outside the glyph range.
        if storage.string.hasSuffix("\n") { fragments += 1 }
        let used = manager.usedRect(for: container)
        let font = bodyRange.length > 0
            ? storage.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont : nil
        return Diagnostics(body: storage.attributedSubstring(from: bodyRange).string, bodyFontSize: font?.pointSize ?? 0,
                           bodyFontName: font?.fontName ?? "",
                           allCharactersLaidOut: NSMaxRange(characters) == storage.length &&
                            used.width <= container.size.width + 0.5 && used.height <= container.size.height + 0.5,
                           sourceLineCount: expectedLineCount, renderedLineCount: fragments)
    }
}
