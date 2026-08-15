import Foundation

final class GitHubUpdateChecker {
    struct Release {
        let version: String
        let pageURL: URL
    }

    enum CheckResult {
        case updateAvailable(currentVersion: String, release: Release)
        case upToDate(currentVersion: String)
        case failed(message: String)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let pageURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case pageURL = "html_url"
        }
    }

    private struct SemanticVersion: Comparable {
        let components: [Int]

        init?(_ value: String) {
            guard let start = value.firstIndex(where: { $0.isNumber }) else { return nil }
            let numericPrefix = value[start...].prefix { $0.isNumber || $0 == "." }
            let parts = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
            let parsedComponents = parts.compactMap { Int($0) }
            guard !parts.isEmpty, parsedComponents.count == parts.count else { return nil }
            components = parsedComponents
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            let count = max(lhs.components.count, rhs.components.count)
            for index in 0..<count {
                let left = index < lhs.components.count ? lhs.components[index] : 0
                let right = index < rhs.components.count ? rhs.components[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }

    private let endpoint = URL(
        string: "https://api.github.com/repos/ChaitanyaSai-Meka/EdgeBeat/releases/latest"
    )!
    private let releasesPage = URL(
        string: "https://github.com/ChaitanyaSai-Meka/EdgeBeat/releases"
    )!
    private var task: URLSessionDataTask?

    func check(completion: @escaping (CheckResult) -> Void) {
        guard let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
              let parsedCurrentVersion = SemanticVersion(currentVersion) else {
            completion(.failed(message: "The installed app version could not be determined."))
            return
        }

        task?.cancel()

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("EdgeBeat/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result = self?.process(
                data: data,
                response: response,
                error: error,
                currentVersion: currentVersion,
                parsedCurrentVersion: parsedCurrentVersion
            ) ?? .failed(message: "The update check was cancelled.")

            DispatchQueue.main.async {
                completion(result)
            }
        }
        task?.resume()
    }

    private func process(data: Data?, response: URLResponse?, error: Error?,
                         currentVersion: String,
                         parsedCurrentVersion: SemanticVersion) -> CheckResult {
        if let error {
            return .failed(message: error.localizedDescription)
        }

        guard let response = response as? HTTPURLResponse else {
            return .failed(message: "GitHub returned an invalid response.")
        }

        guard response.statusCode == 200 else {
            if response.statusCode == 404 {
                return .failed(message: "No published EdgeBeat release was found on GitHub.")
            }
            return .failed(message: "GitHub returned HTTP \(response.statusCode).")
        }

        guard let data,
              let githubRelease = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let releaseVersion = SemanticVersion(githubRelease.tagName) else {
            return .failed(message: "The latest GitHub release has an invalid version number.")
        }

        guard releaseVersion > parsedCurrentVersion else {
            return .upToDate(currentVersion: currentVersion)
        }

        let pageURL = isEdgeBeatReleaseURL(githubRelease.pageURL)
            ? githubRelease.pageURL
            : releasesPage
        return .updateAvailable(
            currentVersion: currentVersion,
            release: Release(version: githubRelease.tagName, pageURL: pageURL)
        )
    }

    private func isEdgeBeatReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host == "github.com"
            && url.path.hasPrefix("/ChaitanyaSai-Meka/EdgeBeat/releases/")
    }
}
