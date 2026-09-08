import Foundation
import XCTest
@testable import PoemCore

final class PoemCoreTests: XCTestCase {
    func testLineBreaksStanzasEntitiesAndAttribution() throws {
        let data = feed([item(title: "A test&rsquo;s title &amp; morning", body: """
            <p>by Example Writer<br/>tr. Example Translator</p>
            <p>One &amp; two<br/>A &ldquo;bright&rdquo; line &#8212; here</p>
            <p>&nbsp;&nbsp;Indented line<br/>Last line &#x1F33F;.</p>
            """)])
        let poem = try XCTUnwrap(PoemFeedParser().parse(data).first)
        XCTAssertEqual(poem.title, "A test’s title & morning")
        XCTAssertEqual(poem.author, "Example Writer · tr. Example Translator")
        XCTAssertEqual(poem.body, "One & two\nA “bright” line — here\n\n  Indented line\nLast line 🌿.")
    }

    func testBylineInsideFirstParagraph() throws {
        let poem = try XCTUnwrap(PoemFeedParser().parse(feed([item(body: "<p>by Example Writer<br/>First line<br/><br/>Second stanza</p>")])).first)
        XCTAssertEqual(poem.author, "Example Writer")
        XCTAssertEqual(poem.body, "First line\n\nSecond stanza")
    }

    func testFirstVerseIndentationSurvivesBylineRemoval() throws {
        for prefix in ["<p>by Example Writer</p>", ""] {
            let poem = try XCTUnwrap(PoemFeedParser().parse(feed([
                item(body: prefix + "<p>&nbsp;&nbsp;First line<br/>Next line</p>")
            ])).first)
            XCTAssertEqual(poem.body, "  First line\nNext line")
        }
    }

    func testExplicitVerseBreaksSurviveHTMLSourcePaddingAndNestedBlocks() throws {
        let poem = try XCTUnwrap(PoemFeedParser().parse(feed([item(body: """
            <p>by Example Writer</p>
            <div><p>First line<br/>
                <br/> <br/>Second line<br/><br/><br/><br/>Third line</p></div>
            <p>Last stanza</p>
            """)])).first)
        XCTAssertEqual(poem.body, "First line\n\n\nSecond line\n\n\n\nThird line\n\nLast stanza")
    }

    func testLiteralUnicodeIndentationSurvivesOnFirstAndLaterLines() throws {
        let poem = try XCTUnwrap(PoemFeedParser().parse(feed([item(body:
            "<p>by Example Writer</p><p>\u{00A0}\u{00A0}First line<br/>\u{2003}Second line</p>"
        )])).first)
        XCTAssertEqual(poem.body, "\u{00A0}\u{00A0}First line\n\u{2003}Second line")
    }

    func testPreformattedPoemRetainsLineBreaksIndentationAndTrailingSpaces() throws {
        let poem = try XCTUnwrap(PoemFeedParser().parse(feed([item(body:
            "<p>by Example Writer</p>\n<pre>  First line\n\tSecond <em>line</em>\n\n\n    Last line  </pre>"
        )])).first)
        XCTAssertEqual(poem.author, "Example Writer")
        XCTAssertEqual(poem.body, "  First line\n\tSecond line\n\n\n    Last line  ")
    }

    func testInlineFormattingDoesNotCreateVerseBreaksAndDecorationsAreRemoved() throws {
        let poem = try XCTUnwrap(PoemFeedParser().parse(feed([item(body: """
            <p>by Example Writer</p><figure><img src="photo.jpg"/><figcaption>A caption</figcaption></figure>
            <p>A <em>small</em> line<br/>And <a href="https://example.com">another</a></p>
            <script>bad()</script><p class="advertisement">Ad content</p>
            """)])).first)
        XCTAssertEqual(poem.body, "A small line\nAnd another")
    }

    func testParserSkipsInvalidEntriesAndSortsByPublicationDate() throws {
        let data = feed([
            item(title: "Old", date: "Mon, 01 Jun 2026 10:00:00 +0000"),
            item(title: "New", date: "Tue, 02 Jun 2026 10:00:00 +0000"),
            item(title: "Insecure", link: "http://example.com/poem"),
            item(title: "Undated", date: "bad date"),
            item(title: "Empty", body: "<p>by Example Writer</p>")
        ])
        XCTAssertEqual(try PoemFeedParser().parse(data).map(\.title), ["New", "Old"])
    }

    func testRejectsMalformedXMLAndOversizedFeed() {
        XCTAssertThrowsError(try PoemFeedParser().parse(Data("<rss><channel>".utf8)))
        XCTAssertThrowsError(try PoemFeedParser().parse(Data("<html/>".utf8)))
        XCTAssertThrowsError(try PoemFeedParser().parse(Data(repeating: 32, count: PoemService.maximumFeedBytes + 1)))
    }

    func testNewestPublishedPoemIsCachedAndFailurePreservesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = PoemService(cacheDirectory: directory)
        XCTAssertNil(service.loadCached())
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-02T12:00:00Z"))
        let data = feed([
            item(title: "Tomorrow", date: "Wed, 03 Jun 2026 10:00:00 +0000"),
            item(title: "Today", date: "Tue, 02 Jun 2026 10:00:00 +0000"),
            item(title: "Yesterday", date: "Mon, 01 Jun 2026 10:00:00 +0000")
        ])
        let latest = try service.acceptFeed(data, now: now)
        XCTAssertEqual(latest.title, "Today")
        XCTAssertEqual(service.loadCached(), latest)
        XCTAssertThrowsError(try service.acceptFeed(Data("not XML".utf8), now: now))
        XCTAssertEqual(service.loadCached(), latest)
        XCTAssertThrowsError(try service.acceptFeed(feed([item(date: "Wed, 03 Jun 2026 10:00:00 +0000")]), now: now))
        XCTAssertEqual(service.loadCached(), latest)
    }

    func testUnreadableCacheIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken JSON".utf8).write(to: directory.appendingPathComponent("latest-poem.json"))
        XCTAssertNil(PoemService(cacheDirectory: directory).loadCached())
    }

    // Opt-in smoke check of a separately downloaded feed; no third-party poems
    // are included in source control or printed in test output.
    func testRealFeedWhenFixtureIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["POEM_FEED_FIXTURE"] else { throw XCTSkip("No local live-feed fixture provided") }
        let poems = try PoemFeedParser().parse(Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(poems.isEmpty)
        XCTAssertTrue(poems.allSatisfy { !$0.title.isEmpty && !$0.author.isEmpty && !$0.body.isEmpty })
        XCTAssertTrue(poems.allSatisfy { !$0.body.lowercased().hasPrefix("by ") })
        XCTAssertTrue(poems.allSatisfy { $0.url.scheme == "https" })
    }

    private func feed(_ items: [String]) -> Data {
        Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss version=\"2.0\"><channel>\(items.joined())</channel></rss>".utf8)
    }

    private func item(title: String = "Test poem", body: String = "<p>by Example Writer</p><p>A synthetic line.</p>",
                      link: String = "https://example.com/poem", date: String = "Mon, 01 Jun 2026 10:00:00 +0000") -> String {
        "<item><title><![CDATA[\(title)]]></title><description><![CDATA[\(body)]]></description><link>\(link)</link><pubDate>\(date)</pubDate></item>"
    }
}
