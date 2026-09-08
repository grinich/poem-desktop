import Foundation

public struct PoemFeedParser {
    public init() {}

    public func parse(_ data: Data) throws -> [Poem] {
        guard data.count <= PoemService.maximumFeedBytes else { throw PoemError.responseTooLarge }
        let delegate = RSSDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isRSS else { throw PoemError.invalidFeed }
        return delegate.items.compactMap(Self.poem).sorted { $0.publishedAt > $1.publishedAt }
    }

    private static func poem(_ item: [String: String]) -> Poem? {
        guard let link = item["link"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: link), isSecureWebURL(url),
              let published = item["pubDate"].flatMap(parseDate) else { return nil }
        let title = HTMLText.plainText(item["title"] ?? "").replacingOccurrences(of: "\n", with: " ")
        let description = item["content:encoded"].flatMap { $0.isEmpty ? nil : $0 }
            ?? item["description"] ?? ""
        var lines = HTMLText.plainText(description).components(separatedBy: "\n")
        var author = ""
        if let first = lines.first, first.lowercased().hasPrefix("by ") {
            author = String(first.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
            // Translators belong with the attribution, not among the poem's lines.
            if let next = lines.first, isTranslationCredit(next) {
                author += " · " + next.trimmingCharacters(in: .whitespaces)
                lines.removeFirst()
            }
        }
        let body = HTMLText.trimmingBlankLines(lines.joined(separator: "\n"))
        guard !title.isEmpty, !body.isEmpty else { return nil }
        return Poem(title: title, author: author, body: body, url: url, publishedAt: published)
    }

    private static func isTranslationCredit(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        return text.hasPrefix("tr. ") || text.hasPrefix("translated by ") || text.hasPrefix("translation by ")
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }
}

private final class RSSDelegate: NSObject, XMLParserDelegate {
    var items: [[String: String]] = []
    var isRSS = false
    private var item: [String: String]?
    private var field: String?
    private var depth = 0
    private var fieldDepth = 0
    private let fields: Set<String> = ["title", "description", "content:encoded", "link", "pubDate"]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth == 1 { isRSS = name.lowercased() == "rss" }
        if name == "item" { item = [:] }
        else if item != nil, field == nil, fields.contains(name) {
            field = name
            fieldDepth = depth
            item?[name] = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let field { item?[field, default: ""] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8), let field { item?[field, default: ""] += text }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item", let item {
            items.append(item)
            self.item = nil
            field = nil
        } else if name == field, depth == fieldDepth { field = nil }
        depth -= 1
    }
}

private enum HTMLText {
    static func plainText(_ html: String) -> String {
        var value = html
        let verseBreak = "\u{E000}\(UUID().uuidString)\u{E001}"
        value = replace(value, "(?is)<!--.*?-->", "")
        value = replace(value, "(?is)<(script|style|iframe|figure|figcaption)\\b[^>]*>.*?</\\1\\s*>", "")
        value = replace(value, "(?is)<(div|p)\\b[^>]*class\\s*=\\s*[\"'][^\"']*\\b(advertisement|tumblr_blog|tmblr-attribution)\\b[^\"']*[\"'][^>]*>.*?</\\1\\s*>", "")
        // Whitespace in <pre> is verse content. Protect it before removing the
        // indentation and line wrapping used only to format the HTML source.
        value = protectingPreformattedWhitespace(value, verseBreak: verseBreak)
        // A feed's HTML source wrapping is not a verse break; <br> and blocks are.
        value = replace(value, "[ \\t]*\\r?\\n[ \\t]*", " ")
        value = replace(value, "(?i)<br\\b[^>]*>", verseBreak)
        value = replace(value, "(?i)</(p|div|blockquote|pre|h[1-6])\\s*>", "\n\n")
        value = replace(value, "(?i)<li\\b[^>]*>", "\n")
        value = replace(value, "<[^>]*>", "")
        // Only ASCII whitespace is HTML source padding. Literal Unicode spaces,
        // encoded indentation, and whitespace protected inside <pre> survive.
        let sourceWhitespace = CharacterSet(charactersIn: " \t\r")
        value = value.components(separatedBy: "\n")
            .map { line in
                line.components(separatedBy: verseBreak)
                    .map { $0.trimmingCharacters(in: sourceWhitespace) }
                    .joined(separator: verseBreak)
            }.joined(separator: "\n")
        // Nested HTML blocks share a stanza boundary, but explicitly authored
        // <br> breaks must not be collapsed, even when several occur together.
        value = replace(value, "\\n{3,}", "\n\n")
        value = decodeEntities(value)
        value = value.replacingOccurrences(of: verseBreak, with: "\n")
        return trimmingBlankLines(value)
    }

    private static func protectingPreformattedWhitespace(_ input: String, verseBreak: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?is)(<pre\\b[^>]*>)(.*?)(</pre\\s*>)") else { return input }
        var result = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let contentRange = Range(match.range(at: 2), in: input),
                  let replacementRange = Range(match.range(at: 2), in: result) else { continue }
            let content = String(input[contentRange])
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: verseBreak)
                .replacingOccurrences(of: " ", with: "&#32;")
                .replacingOccurrences(of: "\t", with: "&#9;")
            result.replaceSubrange(replacementRange, with: content)
        }
        return result
    }

    static func trimmingBlankLines(_ value: String) -> String {
        var lines = value.components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func replace(_ value: String, _ pattern: String, _ replacement: String) -> String {
        value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func decodeEntities(_ input: String) -> String {
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "ensp": " ", "emsp": " ", "thinsp": " ", "hairsp": " ", "zwnj": "‌", "zwj": "‍",
            "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
            "ndash": "–", "mdash": "—", "hellip": "…", "bull": "•", "middot": "·",
            "copy": "©", "reg": "®", "trade": "™", "deg": "°", "times": "×", "divide": "÷",
            "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "euro": "€", "pound": "£",
            "cent": "¢", "yen": "¥", "sect": "§", "para": "¶", "dagger": "†", "Dagger": "‡",
            "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú", "yacute": "ý",
            "Aacute": "Á", "Eacute": "É", "Iacute": "Í", "Oacute": "Ó", "Uacute": "Ú", "Yacute": "Ý",
            "agrave": "à", "egrave": "è", "igrave": "ì", "ograve": "ò", "ugrave": "ù",
            "Agrave": "À", "Egrave": "È", "Igrave": "Ì", "Ograve": "Ò", "Ugrave": "Ù",
            "acirc": "â", "ecirc": "ê", "icirc": "î", "ocirc": "ô", "ucirc": "û",
            "Acirc": "Â", "Ecirc": "Ê", "Icirc": "Î", "Ocirc": "Ô", "Ucirc": "Û",
            "auml": "ä", "euml": "ë", "iuml": "ï", "ouml": "ö", "uuml": "ü", "yuml": "ÿ",
            "Auml": "Ä", "Euml": "Ë", "Iuml": "Ï", "Ouml": "Ö", "Uuml": "Ü",
            "atilde": "ã", "ntilde": "ñ", "otilde": "õ", "Atilde": "Ã", "Ntilde": "Ñ", "Otilde": "Õ",
            "aring": "å", "Aring": "Å", "aelig": "æ", "AElig": "Æ", "oslash": "ø", "Oslash": "Ø",
            "ccedil": "ç", "Ccedil": "Ç", "szlig": "ß", "oelig": "œ", "OElig": "Œ", "shy": ""
        ]
        guard let regex = try? NSRegularExpression(pattern: "&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[A-Za-z]+);") else { return input }
        var result = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let wholeRange = Range(match.range, in: result), let nameRange = Range(match.range(at: 1), in: input) else { continue }
            let name = String(input[nameRange])
            var decoded = named[name]
            if name.hasPrefix("#") {
                let isHex = name.dropFirst().lowercased().hasPrefix("x")
                let digits = name.dropFirst(isHex ? 2 : 1)
                if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = UnicodeScalar(code), code != 0 {
                    decoded = String(scalar)
                }
            }
            if let decoded { result.replaceSubrange(wholeRange, with: decoded) }
        }
        return result
    }
}
