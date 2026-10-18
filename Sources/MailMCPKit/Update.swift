import Foundation

/// A release version such as `1.2.0`, compared number by number (`1.10.0` is newer than `1.9.0`).
/// Missing trailing numbers count as zero, so `1.1` equals `1.1.0`.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]

    /// Accepts `1.2.0` and the tag form `v1.2.0`; anything else (a pre-release suffix, words) is nil.
    public init?(_ string: String) {
        let text = string.hasPrefix("v") ? string.dropFirst() : Substring(string)
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...4).contains(numbers.count), numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { a.padded(to: b) == b.padded(to: a) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        a.padded(to: b).lexicographicallyPrecedes(b.padded(to: a))
    }

    private func padded(to other: AppVersion) -> [Int] {
        numbers + Array(repeating: 0, count: max(other.numbers.count - numbers.count, 0))
    }
}

/// The newest published release, read from GitHub's `releases/latest` endpoint (which leaves out
/// drafts and pre-releases).
public struct Release: Equatable, Sendable {
    public static let latestURL = URL(string: "https://api.github.com/repos/mp-consulting/apple-mail-mcp/releases/latest")!
    /// Where the release workflow's assets live. A response pointing elsewhere is refused outright,
    /// before the signature checks that guard the install.
    static let downloadPrefix = "https://github.com/mp-consulting/apple-mail-mcp/releases/download/"

    public enum Failure: Error, Equatable {
        case unreadable
        case badVersion(String)
        /// The release has no `AppleMailMCP-<version>.dmg`, e.g. while the workflow is still building it.
        case noDiskImage
    }

    public let version: AppVersion
    /// The release page, for its notes.
    public let pageURL: URL
    public let diskImageURL: URL

    public init(version: AppVersion, pageURL: URL, diskImageURL: URL) {
        self.version = version
        self.pageURL = pageURL
        self.diskImageURL = diskImageURL
    }

    public static func diskImageName(_ version: AppVersion) -> String { "AppleMailMCP-\(version).dmg" }

    public init(gitHubJSON data: Data) throws(Failure) {
        struct Response: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
            let tag_name: String
            let html_url: String
            let assets: [Asset]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let pageURL = URL(string: response.html_url), pageURL.scheme == "https", pageURL.host() == "github.com"
        else { throw .unreadable }
        guard let version = AppVersion(response.tag_name) else { throw .badVersion(response.tag_name) }
        // The name the release workflow gives the image; a stray asset never gets installed.
        guard let asset = response.assets.first(where: { $0.name == Self.diskImageName(version) }),
              asset.browser_download_url.hasPrefix(Self.downloadPrefix),
              let diskImageURL = URL(string: asset.browser_download_url)
        else { throw .noDiskImage }
        self.init(version: version, pageURL: pageURL, diskImageURL: diskImageURL)
    }
}

public enum UpdateSchedule {
    /// One check a day: releases are rare, and GitHub limits unauthenticated API calls.
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastCheck: Date?, now: Date = .now) -> Bool {
        guard let lastCheck else { return true }
        // A clock set back would otherwise postpone the next check until it caught up.
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }
}
