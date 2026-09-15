import Foundation

// MARK: - GitHubReleaseFetcher
//
// Queries a GitHub repo's latest release for the version/last-updated/
// download-count metadata `EdmundExtension` wants to show. Not wired to
// `AdvancedMathExtension` yet — that extension has no repo of its own to
// query (RaTeX's own repo, erweixin/RaTeX, isn't this extension's repo; see
// the stubbed `developer`/`repositoryURL` in EdmundExtension.swift). Wire
// this in once I7T5's own extension repo exists.

public struct GitHubReleaseInfo: Sendable {
    /// The release tag (e.g. "v1.0.0"), as GitHub reports it — untouched, so
    /// callers decide whether/how to strip a leading "v".
    public let version: String
    public let publishedAt: Date
    /// Sum of every release asset's download count. GitHub has no single
    /// "total downloads" field; this is the closest honest proxy for one
    /// release. Callers wanting an all-time total would sum this across
    /// `allReleases`.
    public let downloadCount: Int
}

public enum GitHubReleaseFetcherError: Error {
    case badResponse
}

public enum GitHubReleaseFetcher {
    /// Fetches `owner/repo`'s latest published release. `session` defaults to
    /// `.shared`; tests inject a stubbed session instead of hitting the network.
    public static func latestRelease(owner: String, repo: String,
                                     session: URLSession = .shared) async throws -> GitHubReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GitHubReleaseFetcherError.badResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(ReleaseDTO.self, from: data)
        return GitHubReleaseInfo(version: dto.tag_name, publishedAt: dto.published_at,
                                 downloadCount: dto.assets.reduce(0) { $0 + $1.download_count })
    }

    private struct ReleaseDTO: Decodable {
        let tag_name: String
        let published_at: Date
        let assets: [AssetDTO]
    }

    private struct AssetDTO: Decodable {
        let download_count: Int
    }
}
