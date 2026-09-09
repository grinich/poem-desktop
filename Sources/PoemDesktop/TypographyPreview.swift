import AppKit

@MainActor
final class TypographyPreview: NSView {
    private let caption = NSTextField(labelWithString: "")
    private let sample = NSTextField(labelWithString: "A quiet moment.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(typeface: PoemTypeface, fontSize: CGFloat) {
        caption.stringValue = "Preview · \(String(format: "%g", Double(fontSize))) pt"
        sample.font = typeface.font(size: fontSize)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.97, green: 0.955, blue: 0.925, alpha: 1).cgColor
        layer?.cornerRadius = 9

        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = NSColor(calibratedWhite: 0.38, alpha: 1)
        sample.textColor = .black
        sample.maximumNumberOfLines = 1
        sample.lineBreakMode = .byClipping

        for field in [caption, sample] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }

        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            sample.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            sample.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 6),
            sample.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            sample.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])

        configure(typeface: .georgia, fontSize: 20)
    }
}
