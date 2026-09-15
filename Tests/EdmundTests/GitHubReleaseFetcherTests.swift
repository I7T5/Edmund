import Testing
import Foundation
@testable import EdmundCore

/// Stubs one canned response for any request, so the fetcher's JSON parsing
/// is tested without hitting the network.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData: Data = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("GitHubReleaseFetcher")
struct GitHubReleaseFetcherTests {
    private static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("Parses tag, publish date, and sums asset download counts")
    func parsesLatestRelease() async throws {
        StubURLProtocol.responseData = """
        {
          "tag_name": "v0.1.12",
          "published_at": "2026-06-25T00:00:00Z",
          "assets": [
            { "download_count": 120 },
            { "download_count": 30 }
          ]
        }
        """.data(using: .utf8)!

        let info = try await GitHubReleaseFetcher.latestRelease(
            owner: "erweixin", repo: "RaTeX", session: Self.stubbedSession())

        #expect(info.version == "v0.1.12")
        #expect(info.downloadCount == 150)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 25
        #expect(info.publishedAt == calendar.date(from: c))
    }
}
