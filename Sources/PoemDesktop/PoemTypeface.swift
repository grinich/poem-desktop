import AppKit

/// Native serif faces shared by desktop measurement, drawing, and the reader.
enum PoemTypeface: String, CaseIterable {
    case georgia, palatino, baskerville, timesNewRoman, iowanOldStyle

    var displayName: String {
        switch self {
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .baskerville: return "Baskerville"
        case .timesNewRoman: return "Times New Roman"
        case .iowanOldStyle: return "Iowan Old Style"
        }
    }

    private var fontNames: (regular: String, italic: String) {
        switch self {
        case .georgia: return ("Georgia", "Georgia-Italic")
        case .palatino: return ("Palatino-Roman", "Palatino-Italic")
        case .baskerville: return ("Baskerville", "Baskerville-Italic")
        case .timesNewRoman: return ("TimesNewRomanPSMT", "TimesNewRomanPS-ItalicMT")
        case .iowanOldStyle: return ("IowanOldStyle-Roman", "IowanOldStyle-Italic")
        }
    }

    // Some macOS installations omit supplemental fonts. Offer only installed faces.
    @MainActor static var available: [Self] {
        let installed = allCases.filter {
            NSFont(name: $0.fontNames.regular, size: 20) != nil &&
                NSFont(name: $0.fontNames.italic, size: 20) != nil
        }
        return installed.isEmpty ? [.georgia] : installed
    }

    @MainActor func font(size: CGFloat, italic: Bool = false) -> NSFont {
        NSFont(name: italic ? fontNames.italic : fontNames.regular, size: size) ??
            NSFont(name: italic ? "Georgia-Italic" : "Georgia", size: size) ??
            NSFont(name: italic ? "TimesNewRomanPS-ItalicMT" : "TimesNewRomanPSMT", size: size) ??
            NSFont.systemFont(ofSize: size)
    }
}
