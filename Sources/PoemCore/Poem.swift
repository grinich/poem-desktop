import Foundation

public struct Poem: Codable, Equatable, Sendable {
    public let title: String
    public let author: String
    public let body: String
    public let url: URL
    public let publishedAt: Date

    public init(title: String, author: String, body: String, url: URL, publishedAt: Date) {
        self.title = title
        self.author = author
        self.body = body
        self.url = url
        self.publishedAt = publishedAt
    }
}

public enum PoemError: LocalizedError {
    case invalidFeed
    case noPublishedPoem
    case insecureURL
    case unexpectedResponse
    case httpStatus(Int)
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidFeed: return "The poem feed could not be read."
        case .noPublishedPoem: return "The feed does not contain a published poem yet."
        case .insecureURL: return "The poem source must use a secure HTTPS connection."
        case .unexpectedResponse: return "The poem source returned an unexpected response."
        case .httpStatus(let status): return "The poem source returned HTTP \(status)."
        case .responseTooLarge: return "The poem feed is larger than expected."
        }
    }
}

func isSecureWebURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
        && url.user == nil && url.password == nil
}
