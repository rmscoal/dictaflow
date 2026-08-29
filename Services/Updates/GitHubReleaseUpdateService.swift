import Foundation

protocol AppUpdateChecking: AnyObject {
    func latestRelease() async throws -> AppRelease
}

nonisolated enum AppUpdateCheckError: LocalizedError {
    case noPublishedRelease
    case invalidServerResponse
    case requestFailed(statusCode: Int)
    case invalidRelease
    case missingDownloadableDMG
    case untrustedReleaseURL

    var errorDescription: String? {
        switch self {
        case .noPublishedRelease:
            return "DictaFlow does not have a published GitHub release yet."
        case .invalidServerResponse:
            return "GitHub returned an invalid update response."
        case .requestFailed(let statusCode):
            return "GitHub could not complete the update check (HTTP \(statusCode))."
        case .invalidRelease:
            return "The latest GitHub release does not have a valid version tag."
        case .missingDownloadableDMG:
            return "The latest GitHub release does not include a downloadable DMG."
        case .untrustedReleaseURL:
            return "The latest release did not provide a trusted GitHub URL."
        }
    }
}

actor GitHubReleaseUpdateService: AppUpdateChecking {
    private struct ReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let state: String
            let size: Int

            var isDownloadableDMG: Bool {
                state == "uploaded"
                    && size > 0
                    && name.lowercased().hasSuffix(".dmg")
            }
        }

        let tagName: String
        let releasePageURL: URL
        let isDraft: Bool
        let isPrerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case releasePageURL = "html_url"
            case isDraft = "draft"
            case isPrerelease = "prerelease"
            case assets
        }
    }

    nonisolated private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/rmscoal/dictaflow/releases/latest"
    )!

    private let session: URLSession
    private let decoder: JSONDecoder

    init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.session = session
        self.decoder = decoder
    }

    func latestRelease() async throws -> AppRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("DictaFlow", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateCheckError.invalidServerResponse
        }

        if httpResponse.statusCode == 404 {
            throw AppUpdateCheckError.noPublishedRelease
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateCheckError.requestFailed(statusCode: httpResponse.statusCode)
        }

        guard let releaseResponse = try? decoder.decode(ReleaseResponse.self, from: data) else {
            throw AppUpdateCheckError.invalidRelease
        }
        guard
            !releaseResponse.isDraft,
            !releaseResponse.isPrerelease,
            let version = AppVersion(releaseResponse.tagName)
        else {
            throw AppUpdateCheckError.invalidRelease
        }
        guard releaseResponse.assets.contains(where: \.isDownloadableDMG) else {
            throw AppUpdateCheckError.missingDownloadableDMG
        }

        let release = AppRelease(
            version: version,
            releasePageURL: releaseResponse.releasePageURL
        )

        guard release.hasTrustedReleasePageURL else {
            throw AppUpdateCheckError.untrustedReleaseURL
        }

        return release
    }
}
