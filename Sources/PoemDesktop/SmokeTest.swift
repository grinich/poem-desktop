import AppKit
import PoemCore

@MainActor
enum SmokeTest {
    static func run(delegate: AppDelegate, arguments: [String]) async {
        do {
            func value(after flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
                return arguments[index + 1]
            }
            let directory = URL(fileURLWithPath: value(after: "--output-dir") ?? "/tmp/poem-desktop-smoke", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let poem: Poem
            if let path = value(after: "--feed-file") {
                let poems = try PoemFeedParser().parse(Data(contentsOf: URL(fileURLWithPath: path)))
                guard let first = poems.first(where: { $0.publishedAt <= Date() }) else { throw Failure("No current poem") }
                poem = first
            } else {
                poem = samplePoem(lines: 34)
            }
            delegate.setPoem(poem)
            guard let window = delegate.overlay, let view = delegate.poemView else { throw Failure("No overlay") }
            try check(NSApp.activationPolicy() == .accessory, "No Dock icon")
            try check(window.ignoresMouseEvents, "Click-through overlay")
            try check(!window.canBecomeKey && !window.canBecomeMain, "Does not take keyboard focus")
            try check(window.level.rawValue < NSWindow.Level.normal.rawValue, "Behind application windows")
            try check(window.level.rawValue > Int(CGWindowLevelForKey(.desktopWindow)), "Above wallpaper")
            try check(window.collectionBehavior.contains(.canJoinAllSpaces), "Across desktop Spaces")
            try check(!window.isOpaque && window.backgroundColor == .clear && !window.hasShadow, "Transparent, no chrome")
            try check(window.isVisible, "Overlay is visible")
            if let screen = NSScreen.screens.first {
                try check(window.frame.maxY <= screen.visibleFrame.maxY, "Below menu bar")
                try check(window.frame.minY >= screen.visibleFrame.minY, "Entire poem stays on desktop")
                print("DISPLAY \(screen.frame) visible \(screen.visibleFrame) overlay \(window.frame)")
            }
            var report: [String] = ["Native behavior: PASS", "Poem: \(poem.title)", "Author: \(poem.author)"]
            view.displayIfNeeded()
            let current = view.diagnostics
            try validate(view: view, poem: poem, label: "Current desktop")
            try render(view: view, to: directory.appendingPathComponent("current-overlay.png"))
            report.append("Current desktop: \(current.columnCount) columns, full poem visible, \(current.bodyFontSize) pt")

            let unusualHeader = Poem(title: String(repeating: "A long but complete title for a small desktop. ", count: 7),
                                     author: String(repeating: "A poet and a translator. ", count: 8),
                                     body: samplePoem(lines: 12).body,
                                     url: poem.url, publishedAt: Date())
            let extraordinaryLine = Poem(title: "Synthetic overflow contingency", author: "Local test",
                                         body: String(repeating: "An unusually long original line. ", count: 1000),
                                         url: poem.url, publishedAt: Date())
            let cases: [(String, NSSize, Poem, CGFloat)] = [
                ("laptop", NSSize(width: 1168, height: 224), poem, 1),
                ("desktop", NSSize(width: 1588, height: 432), poem, 1),
                ("short", NSSize(width: 1168, height: 224), samplePoem(lines: 4), 1),
                ("smallest", NSSize(width: 1168, height: 224), poem, 0.7),
                ("smaller", NSSize(width: 1168, height: 224), poem, 0.85),
                ("smallest-short", NSSize(width: 1168, height: 224), samplePoem(lines: 4), 0.7),
                ("smaller-short", NSSize(width: 1168, height: 224), samplePoem(lines: 4), 0.85),
                ("long", NSSize(width: 1168, height: 224), samplePoem(lines: 180), 1),
                ("larger", NSSize(width: 1168, height: 224), poem, 1.3),
                ("long-header", NSSize(width: 1168, height: 224), unusualHeader, 1.3),
                ("extreme-line", NSSize(width: 1168, height: 224), extraordinaryLine, 1),
                ("many-lines", NSSize(width: 1168, height: 224), samplePoem(lines: 1000), 1)
            ]
            for (name, size, item, scale) in cases {
                let height = PoemView.preferredHeight(for: item, width: size.width,
                                                     targetHeight: size.height, maximumHeight: 840, fontScale: scale)
                let testView = PoemView(frame: NSRect(origin: .zero, size: NSSize(width: size.width, height: height)))
                testView.poem = item
                testView.fontScale = scale
                let d = testView.diagnostics
                try validate(view: testView, poem: item, label: name)
                if name == "laptop" || name == "desktop" || name == "short" {
                    try check(d.bodyFontSize >= 18, "\(name): comfortable text size")
                }
                if name == "smallest-short" || name == "smaller-short" {
                    try check(abs(d.bodyFontSize - 20 * scale) < 0.01, "\(name): respects the smaller text preference")
                }
                if name == "extreme-line" {
                    try check(d.usedEmergencyFit && testView.needsLargerReadingView, "Emergency full-canvas fallback is active")
                }
                try render(view: testView, to: directory.appendingPathComponent("\(name).png"))
                report.append("\(name): PASS · \(d.columnCount) columns · \(d.sourceLines.count) original lines · \(d.bodyFontSize) pt · \(height) pt high")
            }
            let reader = PoemReader()
            for item in [poem, extraordinaryLine, samplePoem(lines: 1000)] {
                reader.prepare(item)
                let d = reader.diagnostics
                try check(d.body == item.body, "Reader retains the exact full poem")
                try check(d.allCharactersLaidOut && d.bodyFontSize == 21, "Reader lays out all text at comfortable size")
                try check(d.renderedLineCount == d.sourceLineCount, "Reader does not wrap original lines")
            }
            report.append("Overflow contingency: full-canvas fallback and 21-point reader pass extreme-line and 1000-line checks")

            // Reuse the same view so changing a typeface must also discard its
            // cached measurement. The short poem fits every font at exactly 20 pt.
            let typefaceView = PoemView(frame: NSRect(x: 0, y: 0, width: 1358, height: 840))
            let shortPoem = samplePoem(lines: 4)
            typefaceView.poem = shortPoem
            _ = typefaceView.diagnostics
            for typeface in PoemTypeface.allCases {
                typefaceView.typeface = typeface
                let changed = typefaceView.diagnostics
                let expectedFont = typeface.font(size: 20)
                try check(changed.bodyFontName == expectedFont.fontName,
                          "\(typeface.displayName): changing typeface updates the cached layout font")
                try check(abs(changed.bodyFontSize - 20) < 0.01,
                          "\(typeface.displayName): changing typeface preserves the size preference")
                let firstLine = shortPoem.body.components(separatedBy: "\n")[0]
                let expectedWidth = (firstLine as NSString).size(withAttributes: [.font: expectedFont]).width
                try check(abs((changed.lineFrames.first?.width ?? 0) - expectedWidth) < 0.01,
                          "\(typeface.displayName): line width is measured with the selected font")
                try validate(view: typefaceView, poem: shortPoem, label: "Changed to \(typeface.displayName)")

                for (name, item) in [("normal", poem), ("long", samplePoem(lines: 180)),
                                     ("extreme-line", extraordinaryLine)] {
                    let height = PoemView.preferredHeight(for: item, width: 1168, targetHeight: 224,
                                                         maximumHeight: 840, fontScale: 1, typeface: typeface)
                    let fontView = PoemView(frame: NSRect(x: 0, y: 0, width: 1168, height: height))
                    fontView.poem = item
                    fontView.typeface = typeface
                    let d = fontView.diagnostics
                    let label = "\(typeface.displayName) \(name)"
                    try check(d.bodyFontName == expectedFont.fontName, "\(label): uses selected typeface")
                    try validate(view: fontView, poem: item, label: label)
                    if name == "extreme-line" {
                        try check(d.usedEmergencyFit && fontView.needsLargerReadingView,
                                  "\(label): retains the emergency full-poem fallback")
                    }
                    if name == "normal" {
                        try render(view: fontView, to: directory.appendingPathComponent("typeface-\(typeface.rawValue).png"))
                    }
                    reader.prepare(item, typeface: typeface)
                    let reading = reader.diagnostics
                    try check(reading.bodyFontName == typeface.font(size: 21).fontName,
                              "\(label): reader uses the selected typeface")
                    try check(reading.body == item.body && reading.allCharactersLaidOut && reading.bodyFontSize == 21,
                              "\(label): reader shows the complete poem at comfortable size")
                    try check(reading.renderedLineCount == reading.sourceLineCount,
                              "\(label): reader preserves every original line break")
                }
                report.append("\(typeface.displayName): PASS · selected font measurements · cached layout changes · full normal, long, and extreme poems · matching reader without wrapping")
            }
            if let path = value(after: "--feed-file") {
                let poems = try PoemFeedParser().parse(Data(contentsOf: URL(fileURLWithPath: path)))
                for (index, item) in poems.enumerated() {
                    let height = PoemView.preferredHeight(for: item, width: 1358, targetHeight: 272,
                                                         maximumHeight: 869, fontScale: 1)
                    let checkView = PoemView(frame: NSRect(x: 0, y: 0, width: 1358, height: height))
                    checkView.poem = item
                    try validate(view: checkView, poem: item, label: "Feed poem \(index + 1)")
                }
                report.append("All \(poems.count) feed poems: full text visible; exact line and stanza sequence; no wrapping or paging")
            }
            let text = report.joined(separator: "\n") + "\n"
            try text.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            print(text)
            print("SMOKE TEST PASS: \(directory.path)")
            NSApp.terminate(nil)
        } catch {
            fputs("SMOKE TEST FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw Failure(label) }
    }

    private static func validate(view: PoemView, poem: Poem, label: String) throws {
        let d = view.diagnostics
        try check(d.pageCount == 1, "\(label): single desktop layout")
        try check(d.sourceLines == poem.body.components(separatedBy: "\n"), "\(label): original line breaks")
        try check(d.renderedLines == d.sourceLines, "\(label): every original line drawn once, unchanged, in order")
        try check(d.lineFrames.count == d.sourceLines.count, "\(label): one frame per original verse line")
        try check(d.allTextVisible && d.textFitsContainers, "\(label): all text visible without clipping")
        try check(d.lineFrames.allSatisfy {
            $0.minX >= -0.5 && $0.minY >= -0.5 &&
            $0.maxX <= view.bounds.width + 0.5 && $0.maxY <= view.bounds.height + 0.5
        },
                  "\(label): all original lines inside the desktop")
    }

    private static func samplePoem(lines: Int) -> Poem {
        let body = (1...lines).map { n in
            "Line \(n): the morning light settles softly." + (n % 5 == 0 ? "\n" : "")
        }.joined(separator: "\n")
        return Poem(title: "A quiet beginning", author: "Local layout test", body: body,
                    url: URL(string: "https://apoemaday.tumblr.com/")!, publishedAt: Date())
    }

    private static func render(view: PoemView, to url: URL) throws {
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: Int(view.bounds.width * scale),
                                           pixelsHigh: Int(view.bounds.height * scale),
                                           bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure("Render unavailable") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor(calibratedRed: 0.94, green: 0.93, blue: 0.89, alpha: 1).setFill()
        NSBezierPath(rect: view.bounds).fill()
        context.cgContext.translateBy(x: 0, y: view.bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure("PNG unavailable") }
        try data.write(to: url)
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
