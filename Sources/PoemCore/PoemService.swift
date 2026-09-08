import Foundation

public struct PoemService: Sendable {
    public static let feedURL = URL(string: "https://apoemaday.tumblr.com/rss")!
    static let maximumFeedBytes = 2 * 1024 * 1024
    private let cacheDirectory: URL
    private var cacheURL: URL { cacheDirectory.appendingPathComponent("latest-poem.json") }

    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    public func loadCached() -> Poem? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFeedBytes,
              let data = try? Data(contentsOf: cacheURL),
              let poem = try? JSONDecoder().decode(Poem.self, from: data),
              isSecureWebURL(poem.url), !poem.title.isEmpty, !poem.body.isEmpty,
              poem.publishedAt <= Date() else { return nil }
        return poem
    }

    public func fetchLatest() async throws -> Poem {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: SecureRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.feedURL)
        request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        request.setValue("PoemDesktop/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw PoemError.unexpectedResponse }
        guard let responseURL = response.url, isSecureWebURL(responseURL) else { throw PoemError.insecureURL }
        guard (200...299).contains(response.statusCode) else { throw PoemError.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= Int64(Self.maximumFeedBytes) else { throw PoemError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), Self.maximumFeedBytes))
        for try await byte in bytes {
            guard data.count < Self.maximumFeedBytes else { throw PoemError.responseTooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try acceptFeed(data, now: Date())
    }

    // Shared by network loading and deterministic tests. A failed parse or a feed
    // with only future entries never replaces the last readable cached poem.
    @discardableResult
    func acceptFeed(_ data: Data, now: Date) throws -> Poem {
        let poems = try PoemFeedParser().parse(data)
        guard let latest = poems.first(where: { $0.publishedAt <= now }) else { throw PoemError.noPublishedPoem }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let encoded = try JSONEncoder().encode(latest)
        try encoded.write(to: cacheURL, options: .atomic)
        return latest
    }
}

private final class SecureRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(isSecureWebURL) == true ? request : nil)
    }
}
