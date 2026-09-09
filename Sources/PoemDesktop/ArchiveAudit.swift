import AppKit
import PoemCore

/// Exercises archived source posts with the app's real parser and desktop renderer.
/// Reports contain post metadata and layout measurements, never poem bodies.
@MainActor
enum ArchiveAudit {
    static func run(arguments: [String]) {
        do {
            func value(after flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
                return arguments[index + 1]
            }
            guard let archivePath = value(after: "--archive-dir") else {
                throw Failure("Missing --archive-dir")
            }
            let archive = URL(fileURLWithPath: archivePath, isDirectory: true)
            let output = URL(fileURLWithPath: value(after: "--output-dir") ?? "/tmp/poem-desktop-year-audit",
                             isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let manifestData = try Data(contentsOf: archive.appendingPathComponent("manifest.json"))
            guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
                throw Failure("Archive manifest must be a JSON object")
            }
            let files = try FileManager.default.contentsOfDirectory(
                at: archive.appendingPathComponent("rss", isDirectory: true),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "xml" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else { throw Failure("No RSS archive files found") }
            guard let screen = NSScreen.screens.first else { throw Failure("No attached display available") }

            let parser = PoemFeedParser()
            var poemsByURL: [String: Poem] = [:]
            var parsedItemCount = 0
            var duplicateCount = 0
            var conflicts: [String] = []
            var emptyFeedFiles: [String] = []
            for file in files {
                let items = try parser.parse(Data(contentsOf: file))
                if items.isEmpty { emptyFeedFiles.append(file.lastPathComponent) }
                parsedItemCount += items.count
                for item in items {
                    let key = item.url.absoluteString
                    if let previous = poemsByURL[key] {
                        duplicateCount += 1
                        if previous != item { conflicts.append(key) }
                    } else {
                        poemsByURL[key] = item
                    }
                }
            }
            let poems = poemsByURL.values.sorted {
                $0.publishedAt == $1.publishedAt ? $0.url.absoluteString < $1.url.absoluteString :
                    $0.publishedAt < $1.publishedAt
            }
            guard !poems.isEmpty else { throw Failure("Archive contains no parseable poems") }
            var configurations = [
                Configuration(name: "actual-default", screen: screen.frame, visible: screen.visibleFrame, scale: 1),
                Configuration(name: "actual-larger", screen: screen.frame, visible: screen.visibleFrame, scale: 1.15),
                Configuration(name: "actual-largest", screen: screen.frame, visible: screen.visibleFrame, scale: 1.3),
                Configuration(name: "small-desktop", screen: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              visible: NSRect(x: 0, y: 70, width: 1280, height: 705), scale: 1),
            ]
            if arguments.contains("--all-typefaces") {
                let sizes: [(name: String, scale: CGFloat)] = [
                    ("smallest", 0.7), ("smaller", 0.85), ("default", 1),
                    ("larger", 1.15), ("largest", 1.3),
                ]
                configurations = PoemTypeface.available.flatMap { typeface in
                    let actual = sizes.map { size in
                        Configuration(name: "actual-\(typeface.rawValue)-\(size.name)",
                                      screen: screen.frame, visible: screen.visibleFrame,
                                      scale: size.scale, typeface: typeface)
                    }
                    let small = Configuration(name: "small-desktop-\(typeface.rawValue)",
                                              screen: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                              visible: NSRect(x: 0, y: 70, width: 1280, height: 705),
                                              scale: 1, typeface: typeface)
                    return actual + [small]
                }
            }
            var records: [[String: Any]] = []
            var failures: [[String: Any]] = []
            var measurements: [Measurement] = []
            for (index, poem) in poems.enumerated() {
                let lines = poem.body.components(separatedBy: "\n")
                var layouts: [[String: Any]] = []
                for configuration in configurations {
                    let measurement = autoreleasepool {
                        measure(poem: poem, configuration: configuration)
                    }
                    measurements.append(measurement)
                    layouts.append(measurement.report)
                    if !measurement.errors.isEmpty {
                        failures.append([
                            "url": poem.url.absoluteString, "title": poem.title,
                            "configuration": configuration.name, "typeface": configuration.typeface.displayName,
                            "errors": measurement.errors,
                        ])
                    }
                }
                var record = metadata(poem)
                record["sourceLineCount"] = lines.count
                record["blankLineCount"] = lines.filter(\.isEmpty).count
                record["longestSourceLineCharacters"] = lines.map(\.count).max() ?? 0
                record["widestSourceLineAt20Points"] = widestLine(lines)
                record["widestSourceLineTypeface"] = PoemTypeface.georgia.displayName
                record["layouts"] = layouts
                records.append(record)
                if (index + 1).isMultiple(of: 100) {
                    print("ARCHIVE AUDIT: measured \(index + 1)/\(poems.count) poems")
                }
            }

            let expectedCount = (manifest["expectedParsedCount"] as? NSNumber)?.intValue
            let declaredComplete = manifest["coverageComplete"] as? Bool == true
            var coverageErrors: [String] = []
            if !declaredComplete { coverageErrors.append("Collector has not confirmed complete interval coverage") }
            if let expectedCount {
                if expectedCount != poems.count {
                    coverageErrors.append("Expected \(expectedCount) unique parsed poems; found \(poems.count)")
                }
            } else {
                coverageErrors.append("Manifest lacks expectedParsedCount; parser coverage cannot be verified")
            }
            if !conflicts.isEmpty { coverageErrors.append("Duplicate URLs contain conflicting poem data") }
            if !emptyFeedFiles.isEmpty { coverageErrors.append("One or more RSS batches produced no poems") }
            let coverageVerified = coverageErrors.isEmpty
            let allLayoutsPass = failures.isEmpty
            let allPass = allLayoutsPass && coverageVerified
            let hardest = measurements.sorted(by: Measurement.isHarder)
            var renderedURLs: Set<String> = []
            var examples: [[String: Any]] = []
            for candidate in hardest {
                guard renderedURLs.insert(candidate.poem.url.absoluteString).inserted else { continue }
                let filename = "hardest-\(examples.count + 1)-\(candidate.configuration.name).png"
                let view = makeView(poem: candidate.poem, configuration: candidate.configuration,
                                    frame: candidate.frame)
                try render(view: view, to: output.appendingPathComponent(filename))
                examples.append([
                    "image": filename, "poem": metadata(candidate.poem),
                    "layout": candidate.report,
                ])
                if examples.count == 3 { break }
            }

            let configurationSummaries: [[String: Any]] = configurations.map { configuration in
                let items = measurements.filter { $0.configuration.name == configuration.name }
                return [
                    "name": configuration.name, "fontScale": configuration.scale,
                    "typeface": configuration.typeface.displayName,
                    "screenFrame": rect(configuration.screen), "visibleFrame": rect(configuration.visible),
                    "poemsTested": items.count, "failures": items.filter { !$0.errors.isEmpty }.count,
                    "minimumBodyFontSize": items.map(\.fontSize).min() ?? 0,
                    "maximumOverlayHeight": items.map { $0.frame.height }.max() ?? 0,
                    "maximumColumns": items.map(\.columns).max() ?? 0,
                    "below14PointReadabilityThreshold": items.filter { $0.fontSize < 14 }.count,
                ]
            }
            let report: [String: Any] = [
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
                "status": allPass ? "PASS" : "FAIL",
                "allLayoutsPass": allLayoutsPass, "annualCoverageVerified": coverageVerified,
                "allTypefaces": arguments.contains("--all-typefaces"),
                "method": "Actual PoemFeedParser, AppDelegate.overlayFrame, and PoemView native AppKit layout",
                "checkedInvariants": [
                    "Every parsed source line and blank stanza line is preserved unchanged and in order",
                    "Each source line is drawn exactly once without wrapping",
                    "Every line frame is contained by both the body area and overlay bounds",
                    "Header and body pass native text container visibility checks",
                    "Overlay is fully contained by its display and visible desktop",
                    "Exactly one desktop page; no continuation pages",
                    "The selected typeface is used for the measured body text",
                ],
                "coverage": [
                    "rssFileCount": files.count, "parsedItemsBeforeDeduplication": parsedItemCount,
                    "uniquePoems": poems.count, "duplicatesRemoved": duplicateCount,
                    "conflictingDuplicateURLs": Array(Set(conflicts)).sorted(),
                    "emptyRSSFiles": emptyFeedFiles, "errors": coverageErrors,
                    "earliestParsedDate": ISO8601DateFormatter().string(from: poems.first!.publishedAt),
                    "latestParsedDate": ISO8601DateFormatter().string(from: poems.last!.publishedAt),
                ],
                "archiveManifest": manifest,
                "configurations": configurationSummaries, "layoutChecks": measurements.count,
                "failedLayouts": failures, "hardestExamples": examples, "poems": records,
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: output.appendingPathComponent("annual-layout-audit.json"), options: .atomic)
            try markdown(report: report, summaries: configurationSummaries, poems: poems,
                         measurements: measurements, coverageErrors: coverageErrors,
                         failures: failures, examples: examples, manifest: manifest)
                .write(to: output.appendingPathComponent("annual-layout-audit.md"), atomically: true, encoding: .utf8)
            print("ARCHIVE AUDIT \(allPass ? "PASS" : "FAIL"): \(poems.count) poems, \(measurements.count) layouts, \(failures.count) layout failures; annual coverage \(coverageVerified ? "verified" : "unverified")")
            print("Reports: \(output.path)")
            if !allPass { exit(1) }
            NSApp.terminate(nil)
        } catch {
            fputs("ARCHIVE AUDIT FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    private struct Configuration {
        let name: String
        let screen: NSRect
        let visible: NSRect
        let scale: CGFloat
        var typeface: PoemTypeface = .georgia
    }

    private struct Measurement {
        let poem: Poem
        let configuration: Configuration
        let frame: NSRect
        let fontSize: CGFloat
        let columns: Int
        let errors: [String]
        let report: [String: Any]

        static func isHarder(_ lhs: Self, _ rhs: Self) -> Bool {
            if abs(lhs.fontSize - rhs.fontSize) > 0.001 { return lhs.fontSize < rhs.fontSize }
            if lhs.frame.height != rhs.frame.height { return lhs.frame.height > rhs.frame.height }
            if lhs.columns != rhs.columns { return lhs.columns > rhs.columns }
            return lhs.poem.url.absoluteString < rhs.poem.url.absoluteString
        }
    }

    private static func measure(poem: Poem, configuration: Configuration) -> Measurement {
        let frame = AppDelegate.overlayFrame(screenFrame: configuration.screen, visibleFrame: configuration.visible,
                                             poem: poem, fontScale: configuration.scale, typeface: configuration.typeface)
        let view = makeView(poem: poem, configuration: configuration, frame: frame)
        let diagnostics = view.diagnostics
        let exactSource = diagnostics.sourceLines == poem.body.components(separatedBy: "\n")
        let exactRendered = diagnostics.renderedLines == diagnostics.sourceLines
        let oneFramePerLine = diagnostics.lineFrames.count == diagnostics.sourceLines.count
        let withinBody = diagnostics.lineFrames.allSatisfy { contains(diagnostics.bodyArea, $0) }
        let withinBounds = diagnostics.lineFrames.allSatisfy { contains(view.bounds, $0) }
        let withinDisplay = contains(configuration.screen, frame) && contains(configuration.visible, frame)
        var errors: [String] = []
        if diagnostics.pageCount != 1 { errors.append("Continuation page generated") }
        if !exactSource { errors.append("Parsed source line sequence changed") }
        if !exactRendered { errors.append("Rendered line sequence differs from parsed source") }
        if !oneFramePerLine { errors.append("Line frame count differs from source line count") }
        if !withinBody { errors.append("Line frame extends outside body area") }
        if !withinBounds { errors.append("Line frame extends outside overlay") }
        if !withinDisplay { errors.append("Overlay extends outside visible desktop") }
        if !diagnostics.allTextVisible { errors.append("Native renderer reports hidden text") }
        if !diagnostics.textFitsContainers { errors.append("Native text container clipping") }
        if diagnostics.bodyFontName != configuration.typeface.font(size: 20).fontName {
            errors.append("Measured body font differs from the selected typeface")
        }
        if !diagnostics.bodyFontSize.isFinite || diagnostics.bodyFontSize <= 0 {
            errors.append("Invalid body font size")
        }
        let report: [String: Any] = [
            "configuration": configuration.name, "fontScale": configuration.scale,
            "typeface": configuration.typeface.displayName, "bodyFontName": diagnostics.bodyFontName,
            "passing": errors.isEmpty, "errors": errors,
            "bodyFontSize": diagnostics.bodyFontSize.isFinite ? diagnostics.bodyFontSize : 0,
            "columns": diagnostics.columnCount, "height": frame.height, "overlayFrame": rect(frame),
            "bodyArea": rect(diagnostics.bodyArea), "pageCount": diagnostics.pageCount,
            "sourceLineCount": diagnostics.sourceLines.count, "renderedLineCount": diagnostics.renderedLines.count,
            "exactParsedLineBreaks": exactSource, "exactRenderedLineSequence": exactRendered,
            "oneFramePerSourceLine": oneFramePerLine, "lineFramesWithinBody": withinBody,
            "lineFramesWithinBounds": withinBounds, "overlayWithinVisibleDesktop": withinDisplay,
            "allTextVisible": diagnostics.allTextVisible, "textFitsContainers": diagnostics.textFitsContainers,
            "below14PointReadabilityThreshold": diagnostics.bodyFontSize < 14,
        ]
        return Measurement(poem: poem, configuration: configuration, frame: frame,
                           fontSize: diagnostics.bodyFontSize, columns: diagnostics.columnCount,
                           errors: errors, report: report)
    }

    private static func makeView(poem: Poem, configuration: Configuration, frame: NSRect) -> PoemView {
        let view = PoemView(frame: NSRect(origin: .zero, size: frame.size))
        view.fontScale = configuration.scale
        view.typeface = configuration.typeface
        view.poem = poem
        return view
    }

    private static func contains(_ outer: NSRect, _ inner: NSRect) -> Bool {
        let values = [inner.minX, inner.minY, inner.maxX, inner.maxY,
                      outer.minX, outer.minY, outer.maxX, outer.maxY]
        return values.allSatisfy(\.isFinite) && inner.minX >= outer.minX - 0.02 &&
            inner.minY >= outer.minY - 0.02 && inner.maxX <= outer.maxX + 0.02 &&
            inner.maxY <= outer.maxY + 0.02
    }

    private static func widestLine(_ lines: [String]) -> CGFloat {
        let font = NSFont(name: "Georgia", size: 20) ?? NSFont(name: "TimesNewRomanPSMT", size: 20) ??
            NSFont.systemFont(ofSize: 20)
        return lines.map { NSAttributedString(string: $0, attributes: [.font: font, .ligature: 1]).size().width }.max() ?? 0
    }

    private static func metadata(_ poem: Poem) -> [String: Any] {
        ["title": poem.title, "author": poem.author, "url": poem.url.absoluteString,
         "publishedAt": ISO8601DateFormatter().string(from: poem.publishedAt)]
    }

    private static func rect(_ value: NSRect) -> [String: CGFloat] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }

    private static func markdown(report: [String: Any], summaries: [[String: Any]], poems: [Poem],
                                 measurements: [Measurement], coverageErrors: [String],
                                 failures: [[String: Any]], examples: [[String: Any]],
                                 manifest: [String: Any]) -> String {
        func cell(_ value: Any?) -> String {
            String(describing: value ?? "—").replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
        }
        func decimal(_ value: Any?) -> String {
            guard let number = value as? NSNumber else { return cell(value) }
            return String(format: "%.2f", number.doubleValue)
        }
        let verified = report["annualCoverageVerified"] as? Bool == true
        var lines = [
            "# Annual poem layout audit", "",
            "**\(cell(report["status"]))** — \(poems.count) unique poems, \(measurements.count) native desktop layouts, \(failures.count) layout failures.", "",
            "Archive coverage: **\(verified ? "verified against collector manifest" : "not verified")**. Layout success alone does not establish that every post in the requested year was collected.", "",
        ]
        if let interval = manifest["interval"] as? [String: Any] {
            lines.append("Requested interval: \(cell(interval["startDate"])) through \(cell(interval["endDate"])) (\(cell(interval["timezone"]))).")
            lines.append("")
        }
        for error in coverageErrors { lines.append("- Coverage issue: \(error)") }
        if !coverageErrors.isEmpty { lines.append("") }
        lines += [
            "The audit uses the production RSS parser, adaptive desktop frame, and AppKit poem renderer. It checks every parsed line and blank stanza line, unchanged and in order; one drawing frame per source line; all frames within the body and display; full header/body visibility; and exactly one page.", "",
            "| Configuration | Typeface | Font preference | Poems | Failures | Smallest body type | Tallest overlay | Most columns | Below 14 pt |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
        for summary in summaries {
            lines.append("| \(cell(summary["name"])) | \(cell(summary["typeface"])) | \(decimal(summary["fontScale"]))× | \(cell(summary["poemsTested"])) | \(cell(summary["failures"])) | \(decimal(summary["minimumBodyFontSize"])) pt | \(decimal(summary["maximumOverlayHeight"])) pt | \(cell(summary["maximumColumns"])) | \(cell(summary["below14PointReadabilityThreshold"])) |")
        }
        lines += ["", "The 1280 × 800 case reserves 70 points below for the Dock and 25 points above for the menu bar. Actual-display cases use the attached screen's real visible frame. Font sizes below 14 points are recorded separately as a readability contingency; they do not imply missing or clipped text.", "", "## Most demanding rendered examples", ""]
        for example in examples {
            guard let poem = example["poem"] as? [String: Any], let layout = example["layout"] as? [String: Any] else { continue }
            lines.append("- [\(cell(poem["title"]))](\(cell(poem["url"]))) — \(cell(layout["configuration"])), \(decimal(layout["bodyFontSize"])) pt, \(cell(layout["columns"])) columns. [Rendered image](\(cell(example["image"]))).")
        }
        if !failures.isEmpty {
            lines += ["", "## Layout failures", ""]
            for failure in failures {
                lines.append("- [\(cell(failure["title"]))](\(cell(failure["url"]))) / \(cell(failure["configuration"])): \(cell(failure["errors"]))")
            }
        }
        lines += ["", "## Per-poem results", "",
                  "Metadata and measurements only. Complete machine-readable coverage evidence and diagnostics are in `annual-layout-audit.json`.", "",
                  "| Published (UTC) | Poem | Author | Smallest type across cases | Max columns | Max height | Result |",
                  "| --- | --- | --- | ---: | ---: | ---: | --- |"]
        for poem in poems {
            let items = measurements.filter { $0.poem.url == poem.url }
            let passing = items.allSatisfy { $0.errors.isEmpty }
            let date = ISO8601DateFormatter().string(from: poem.publishedAt).prefix(10)
            lines.append("| \(date) | [\(cell(poem.title))](\(poem.url.absoluteString)) | \(cell(poem.author)) | \(decimal(items.map(\.fontSize).min())) pt | \(cell(items.map(\.columns).max())) | \(decimal(items.map { $0.frame.height }.max())) pt | \(passing ? "PASS" : "FAIL") |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(view: PoemView, to url: URL) throws {
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: Int(ceil(view.bounds.width * scale)),
                                           pixelsHigh: Int(ceil(view.bounds.height * scale)),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
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
