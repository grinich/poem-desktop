import AppKit
import PoemCore

/// Draws the whole poem on the desktop, preserving every original verse line.
@MainActor
final class PoemView: NSView {
    struct LayoutDiagnostics {
        let pageCount: Int
        let columnCount: Int
        let bodyFontSize: CGFloat
        let bodyFontName: String
        let sourceLines: [String]
        let renderedLines: [String]
        let lineFrames: [NSRect]
        let bodyArea: NSRect
        let textFitsContainers: Bool
        let allTextVisible: Bool
        let usedEmergencyFit: Bool
    }

    var poem: Poem? { didSet { invalidatePoemLayout() } }
    var fontScale: CGFloat = 1 { didSet { invalidatePoemLayout() } }
    var typeface: PoemTypeface = .georgia { didSet { invalidatePoemLayout() } }
    var usesReadingVeil = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    var pageCount: Int { 1 }
    var needsLargerReadingView: Bool {
        let result = diagnostics
        return result.bodyFontSize < 14 || result.usedEmergencyFit
    }

    var diagnostics: LayoutDiagnostics {
        rebuildLayoutIfNeeded()
        let sourceLines = poem?.body.components(separatedBy: "\n") ?? []
        let scale = layout?.drawingScale ?? 1
        let frames = layout?.lineFrames.map { Self.scaled($0, by: scale) } ?? []
        let area = Self.scaled(layout?.bodyArea ?? .zero, by: scale)
        let bodyFits = frames.allSatisfy { frame in
            frame.minX >= area.minX - 0.01 && frame.maxX <= area.maxX + 0.01 &&
                frame.minY >= area.minY - 0.01 && frame.maxY <= area.maxY + 0.01
        }
        let headerFits: Bool
        if let layout {
            let headerRects: [NSRect] = [layout.header.titleRect, layout.header.authorRect, layout.header.sourceRect]
            headerFits = headerRects.allSatisfy { rect in
                let frame = Self.scaled(rect, by: scale)
                return frame.minX >= 0 && frame.maxX <= bounds.width + 0.01 &&
                    frame.minY >= 0 && frame.maxY <= bounds.height + 0.01
            }
        } else { headerFits = poem == nil }
        let renderedLines = layout?.lines.map(\.string) ?? []
        return LayoutDiagnostics(
            pageCount: 1,
            columnCount: layout?.partition.ranges.count ?? 0,
            bodyFontSize: (layout?.fontSize ?? Self.preferredFontSize(fontScale)) * scale,
            bodyFontName: layout?.lines.first(where: { $0.length > 0 })
                .flatMap { $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont }?.fontName ?? "",
            sourceLines: sourceLines,
            renderedLines: renderedLines,
            lineFrames: frames,
            bodyArea: area,
            textFitsContainers: bodyFits && headerFits,
            allTextVisible: sourceLines == renderedLines && bodyFits && headerFits,
            usedEmergencyFit: layout?.usedEmergencyFit ?? false
        )
    }

    /// Extend below the original desktop strip before sacrificing the preferred type size.
    static func preferredHeight(for poem: Poem?, width: CGFloat, targetHeight: CGFloat,
                                maximumHeight: CGFloat, fontScale: CGFloat,
                                typeface: PoemTypeface = .georgia) -> CGFloat {
        let maximum = max(1, maximumHeight)
        let target = min(maximum, max(1, targetHeight))
        guard let poem, width > 2 * contentInset else { return target }
        let measured = measure(poem: poem, width: width, fontSize: preferredFontSize(fontScale), typeface: typeface)
        guard let availableRows = measured.rowCapacity(height: maximum),
              partition(widths: measured.widths, lines: measured.sourceLines,
                        capacity: availableRows, availableWidth: measured.bodyWidth,
                        gap: measured.columnGap, balance: false) != nil else { return maximum }

        if let rows = measured.rowCapacity(height: target),
           partition(widths: measured.widths, lines: measured.sourceLines,
                     capacity: rows, availableWidth: measured.bodyWidth,
                     gap: measured.columnGap, balance: false) != nil {
            return target
        }

        // The feasibility test is monotonic in row capacity, so this search is bounded.
        var lower = max(1, Int(ceil(Double(measured.lines.count) / 6)))
        var upper = availableRows
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if partition(widths: measured.widths, lines: measured.sourceLines,
                         capacity: middle, availableWidth: measured.bodyWidth,
                         gap: measured.columnGap, balance: false) != nil {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return min(maximum, max(target, ceil(measured.header.bodyTop +
                                            CGFloat(lower) * measured.lineAdvance + contentInset)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidatePoemLayout()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        rebuildLayoutIfNeeded()
        if usesReadingVeil {
            NSColor(calibratedRed: 1, green: 0.99, blue: 0.96, alpha: 0.78).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        guard poem != nil else {
            drawWaitingPlaceholder()
            return
        }
        guard let layout else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.scaleBy(x: layout.drawingScale, y: layout.drawingScale)
        layout.header.title.draw(in: layout.header.titleRect)
        layout.header.author.draw(in: layout.header.authorRect)
        layout.header.source.draw(in: layout.header.sourceRect)
        // Each source line is its own drawing operation: AppKit cannot reflow the verse.
        for (line, frame) in zip(layout.lines, layout.lineFrames) {
            line.draw(at: frame.origin)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private struct Header {
        let title: NSAttributedString
        let author: NSAttributedString
        let source: NSAttributedString
        let titleRect: NSRect
        let authorRect: NSRect
        let sourceRect: NSRect
        let bodyTop: CGFloat
    }

    private struct Partition {
        let ranges: [Range<Int>]
        let widths: [CGFloat]
        var totalWidth: CGFloat { widths.reduce(0, +) }
        var maximumRows: Int { ranges.map(\.count).max() ?? 0 }
    }

    private struct MeasuredPoem {
        let sourceLines: [String]
        let lines: [NSAttributedString]
        let widths: [CGFloat]
        let fontSize: CGFloat
        let lineAdvance: CGFloat
        let columnGap: CGFloat
        let bodyWidth: CGFloat
        let header: Header

        @MainActor func rowCapacity(height: CGFloat) -> Int? {
            let available = height - header.bodyTop - PoemView.contentInset
            guard available >= lineAdvance else { return nil }
            return min(lines.count, Int(floor(available / lineAdvance)))
        }
    }

    private struct TextLayout {
        let lines: [NSAttributedString]
        let lineFrames: [NSRect]
        let fontSize: CGFloat
        let partition: Partition
        let bodyArea: NSRect
        let header: Header
        var drawingScale: CGFloat = 1
        var usedEmergencyFit = false
    }

    private var layout: TextLayout?
    private var layoutIsDirty = true
    private static let contentInset: CGFloat = 12

    private func invalidatePoemLayout() {
        layoutIsDirty = true
        needsDisplay = true
    }

    static func preferredFontSize(_ scale: CGFloat) -> CGFloat {
        min(30, max(14, 20 * (scale.isFinite ? scale : 1)))
    }

    private func rebuildLayoutIfNeeded() {
        guard layoutIsDirty else { return }
        layoutIsDirty = false
        layout = nil
        guard let poem, bounds.width > 2 * Self.contentInset,
              bounds.height > 2 * Self.contentInset else { return }

        let preferredSize = Self.preferredFontSize(fontScale)
        let preferred = Self.measure(poem: poem, width: bounds.width, fontSize: preferredSize, typeface: typeface)
        if let result = Self.makeLayout(preferred, height: bounds.height),
           Self.fits(result, in: bounds.size) {
            layout = result
            return
        }

        // Screen height has already been increased by the window controller. Only now
        // reduce the entire composition together, retaining the full heading and poem.
        var lower: CGFloat = 0
        var upper = preferredSize
        var best: TextLayout?
        for _ in 0..<25 {
            let candidateSize = (lower + upper) / 2
            let candidate = Self.measure(poem: poem, width: bounds.width, fontSize: candidateSize, typeface: typeface)
            if let result = Self.makeLayout(candidate, height: bounds.height),
               Self.fits(result, in: bounds.size) {
                lower = candidateSize
                best = result
            } else {
                upper = candidateSize
            }
        }
        // Below a point, native font measurement can become unstable. The final
        // fallback draws a complete natural-size canvas and scales that canvas,
        // so even an unprecedented poem cannot disappear or lose its last lines.
        if let best, best.fontSize >= 1 {
            layout = best
        } else {
            layout = Self.emergencyLayout(poem: poem, size: bounds.size, fontSize: preferredSize, typeface: typeface)
        }
    }

    private static func scaled(_ rect: NSRect, by scale: CGFloat) -> NSRect {
        NSRect(x: rect.minX * scale, y: rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    private static func fits(_ layout: TextLayout, in size: NSSize) -> Bool {
        let frames = layout.lineFrames + [layout.header.titleRect, layout.header.authorRect, layout.header.sourceRect]
        return frames.allSatisfy {
            let frame = scaled($0, by: layout.drawingScale)
            return frame.minX >= -0.01 && frame.minY >= -0.01 &&
                frame.maxX <= size.width + 0.01 && frame.maxY <= size.height + 0.01
        }
    }

    private static func emergencyLayout(poem: Poem, size: NSSize, fontSize: CGFloat,
                                        typeface: PoemTypeface) -> TextLayout? {
        let natural = measure(poem: poem, width: size.width, fontSize: fontSize, typeface: typeface)
        let canvasWidth = max(size.width, ceil((natural.widths.max() ?? 0) + 2 * contentInset + 1))
        let complete = measure(poem: poem, width: canvasWidth, fontSize: fontSize, typeface: typeface)
        let canvasHeight = ceil(complete.header.bodyTop + CGFloat(complete.lines.count) * complete.lineAdvance + contentInset + 1)
        guard canvasWidth.isFinite, canvasHeight.isFinite, canvasWidth > 0, canvasHeight > 0,
              var result = makeLayout(complete, height: canvasHeight) else { return nil }
        result.drawingScale = min(1, size.width / canvasWidth, size.height / canvasHeight) * 0.999
        result.usedEmergencyFit = true
        return fits(result, in: size) ? result : nil
    }

    private static func measure(poem: Poem, width: CGFloat, fontSize: CGFloat, typeface: PoemTypeface) -> MeasuredPoem {
        let scale = fontSize / 20
        let bodyWidth = max(1, width - 2 * contentInset)
        let font = typeface.font(size: fontSize)
        let sourceLines = poem.body.components(separatedBy: "\n")
        let lineStyle = NSMutableParagraphStyle()
        lineStyle.lineBreakMode = .byClipping
        lineStyle.hyphenationFactor = 0
        let lines = sourceLines.map { line in
            NSAttributedString(string: line, attributes: [
                .font: font, .foregroundColor: NSColor.black,
                .paragraphStyle: lineStyle, .ligature: 1,
            ])
        }
        let sizes = lines.map { $0.size() }
        let lineAdvance = max(font.ascender - font.descender + font.leading,
                              sizes.map(\.height).max() ?? 0,
                              NSAttributedString(string: "Ag", attributes: [.font: font]).size().height)
            + fontSize * 0.13
        return MeasuredPoem(
            sourceLines: sourceLines, lines: lines,
            widths: sizes.map(\.width), fontSize: fontSize,
            lineAdvance: lineAdvance, columnGap: 34 * scale, bodyWidth: bodyWidth,
            header: makeHeader(poem: poem, width: bodyWidth, fontSize: fontSize, typeface: typeface)
        )
    }

    private static func makeHeader(poem: Poem, width: CGFloat, fontSize: CGFloat, typeface: PoemTypeface) -> Header {
        let scale = fontSize / 20
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let title = NSAttributedString(string: poem.title, attributes: [
            .font: typeface.font(size: 25 * scale), .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ])
        let author = NSAttributedString(string: poem.author, attributes: [
            .font: typeface.font(size: 15 * scale, italic: true),
            .foregroundColor: NSColor.black.withAlphaComponent(0.8), .paragraphStyle: paragraph,
        ])
        let source = NSAttributedString(
            string: "A POEM A DAY  ·  \(dateFormatter.string(from: poem.publishedAt))",
            attributes: [.font: NSFont.systemFont(ofSize: 9.5 * scale, weight: .medium),
                         .foregroundColor: NSColor.black.withAlphaComponent(0.58),
                         .kern: 0.65 * scale, .paragraphStyle: paragraph]
        )
        let sourceSize = source.size()
        let alongside = width > 800 * scale && title.size().width + sourceSize.width + 40 * scale < width
        let titleWidth = alongside ? width - sourceSize.width - 40 * scale : width
        func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
            guard text.length > 0 else { return 0 }
            return text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                + 2 * scale
        }
        let titleRect = NSRect(x: contentInset, y: 5 * scale, width: titleWidth,
                               height: height(title, width: titleWidth))
        let authorRect = NSRect(x: contentInset, y: titleRect.maxY + scale, width: width,
                                height: height(author, width: width))
        let sourceWidth = alongside ? min(width, sourceSize.width + scale) : width
        let sourceRect = NSRect(x: alongside ? contentInset + width - sourceWidth : contentInset,
                                y: alongside ? 14 * scale : authorRect.maxY + 2 * scale,
                                width: sourceWidth, height: height(source, width: sourceWidth))
        return Header(title: title, author: author, source: source, titleRect: titleRect,
                      authorRect: authorRect, sourceRect: sourceRect,
                      bodyTop: max(authorRect.maxY, sourceRect.maxY) + 12 * scale)
    }

    private static func makeLayout(_ measured: MeasuredPoem, height: CGFloat) -> TextLayout? {
        guard let capacity = measured.rowCapacity(height: height),
              let columns = partition(widths: measured.widths, lines: measured.sourceLines,
                                      capacity: capacity, availableWidth: measured.bodyWidth,
                                      gap: measured.columnGap, balance: true) else { return nil }
        let bodyArea = NSRect(x: contentInset, y: measured.header.bodyTop,
                              width: measured.bodyWidth,
                              height: height - measured.header.bodyTop - contentInset)
        var frames = [NSRect](repeating: .zero, count: measured.lines.count)
        var x = bodyArea.minX
        for (range, columnWidth) in zip(columns.ranges, columns.widths) {
            for (row, index) in range.enumerated() {
                frames[index] = NSRect(x: x, y: bodyArea.minY + CGFloat(row) * measured.lineAdvance,
                                       width: measured.widths[index], height: measured.lineAdvance)
            }
            x += columnWidth + measured.columnGap
        }
        return TextLayout(lines: measured.lines, lineFrames: frames, fontSize: measured.fontSize,
                          partition: columns, bodyArea: bodyArea, header: measured.header)
    }

    /// Choose the fewest columns that fit. Within that choice, minimize the tallest
    /// column before optimizing widths and preferring stanza boundaries.
    private static func partition(widths: [CGFloat], lines: [String], capacity: Int,
                                  availableWidth: CGFloat, gap: CGFloat, balance: Bool) -> Partition? {
        let count = widths.count
        guard count > 0, capacity > 0, (widths.max() ?? 0) <= availableWidth else { return nil }
        let maximumColumns = min(6, count)
        let minimumColumns = max(1, Int(ceil(Double(count) / Double(capacity))))
        guard minimumColumns <= maximumColumns else { return nil }
        for columns in minimumColumns...maximumColumns {
            let widthBudget = availableWidth - CGFloat(columns - 1) * gap
            guard widthBudget > 0,
                  var candidate = minimumWidthPartition(widths: widths, lines: lines,
                                                        columns: columns, capacity: capacity),
                  candidate.totalWidth <= widthBudget else { continue }
            if balance && columns > 1 {
                var lower = Int(ceil(Double(count) / Double(columns)))
                var upper = candidate.maximumRows
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if let compact = minimumWidthPartition(widths: widths, lines: lines,
                                                           columns: columns, capacity: middle),
                       compact.totalWidth <= widthBudget {
                        candidate = compact
                        upper = middle
                    } else {
                        lower = middle + 1
                    }
                }
            }
            return candidate
        }
        return nil
    }

    private struct PartitionCost {
        var width: CGFloat = .infinity
        var brokenStanzas = Int.max
        var imbalance = Int.max
        var start = -1
    }

    /// Dynamic programming finds the minimum sum of actual column widths, without
    /// imposing equal-width boxes that would wrap long verse lines unnecessarily.
    private static func minimumWidthPartition(widths: [CGFloat], lines: [String],
                                              columns: Int, capacity: Int) -> Partition? {
        let count = widths.count
        guard count >= columns, count <= columns * capacity else { return nil }
        if columns == 1 {
            return Partition(ranges: [0..<count], widths: [widths.max() ?? 0])
        }
        // Exceptionally large imported poems use balanced complete ranges. This keeps
        // fitting bounded without ever dropping a line or allocating a quadratic table.
        if count > 600 {
            var ranges: [Range<Int>] = []
            var start = 0
            for column in 0..<columns {
                let remainingColumns = columns - column
                let length = Int(ceil(Double(count - start) / Double(remainingColumns)))
                let end = start + length
                ranges.append(start..<end)
                start = end
            }
            return Partition(ranges: ranges, widths: ranges.map { widths[$0].max() ?? 0 })
        }
        var table = Array(repeating: Array(repeating: PartitionCost(), count: count + 1),
                          count: columns + 1)
        table[0][0] = PartitionCost(width: 0, brokenStanzas: 0, imbalance: 0, start: 0)
        for column in 1...columns {
            let firstEnd = max(column, count - (columns - column) * capacity)
            let lastEnd = min(count - (columns - column), column * capacity)
            guard firstEnd <= lastEnd else { continue }
            for end in firstEnd...lastEnd {
                let firstStart = max(column - 1, end - capacity)
                let lastStart = min(end - 1, (column - 1) * capacity)
                guard firstStart <= lastStart else { continue }
                var columnWidth: CGFloat = 0
                // Accumulate widths even for starts disallowed by earlier columns.
                for start in stride(from: end - 1, through: firstStart, by: -1) {
                    columnWidth = max(columnWidth, widths[start])
                    guard start <= lastStart, table[column - 1][start].width.isFinite else { continue }
                    let previous = table[column - 1][start]
                    let atStanza = start == 0 || lines[start].isEmpty || lines[start - 1].isEmpty
                    let difference = (end - start) * columns - count
                    let proposal = PartitionCost(width: previous.width + columnWidth,
                                                 brokenStanzas: previous.brokenStanzas + (atStanza ? 0 : 1),
                                                 imbalance: previous.imbalance + difference * difference,
                                                 start: start)
                    let current = table[column][end]
                    let widthTie = abs(proposal.width - current.width) < 0.01
                    if proposal.width < current.width - 0.01 ||
                        (widthTie && proposal.brokenStanzas < current.brokenStanzas) ||
                        (widthTie && proposal.brokenStanzas == current.brokenStanzas &&
                         proposal.imbalance < current.imbalance) {
                        table[column][end] = proposal
                    }
                }
            }
        }
        guard table[columns][count].width.isFinite else { return nil }
        var ranges: [Range<Int>] = []
        var end = count
        for column in stride(from: columns, through: 1, by: -1) {
            let start = table[column][end].start
            guard start >= 0, start < end else { return nil }
            ranges.append(start..<end)
            end = start
        }
        ranges.reverse()
        return Partition(ranges: ranges, widths: ranges.map { widths[$0].max() ?? 0 })
    }

    private func drawWaitingPlaceholder() {
        NSAttributedString(string: "A poem for your day", attributes: [
            .font: typeface.font(size: 25), .foregroundColor: NSColor.black,
        ]).draw(at: NSPoint(x: Self.contentInset, y: 8))
        NSAttributedString(string: "Fetching the latest poem from A Poem A Day…", attributes: [
            .font: typeface.font(size: 16, italic: true),
            .foregroundColor: NSColor.black.withAlphaComponent(0.7),
        ]).draw(at: NSPoint(x: Self.contentInset, y: 46))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}
