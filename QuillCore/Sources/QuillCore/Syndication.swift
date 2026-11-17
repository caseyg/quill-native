import Foundation

/// A copy of a post on another site, such as a Bluesky or Mastodon post made by POSSE.
public struct SyndicatedCopy: Equatable, Identifiable, Sendable {
    public var url: URL
    /// The service's name, for "Open on Bluesky".
    public var service: String
    public var id: URL { url }

    public init(url: URL) {
        self.url = url
        service = SyndicatedCopy.service(for: url)
    }

    /// The name of the service a link points to. Mastodon runs on many hosts, so its post paths identify it.
    public static func service(for url: URL) -> String {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
        let known = ["bsky.app": "Bluesky", "bsky.social": "Bluesky", "twitter.com": "X", "x.com": "X", "threads.net": "Threads", "threads.com": "Threads",
                     "github.com": "GitHub", "flickr.com": "Flickr", "instagram.com": "Instagram", "facebook.com": "Facebook",
                     "linkedin.com": "LinkedIn", "medium.com": "Medium", "micro.blog": "Micro.blog", "tumblr.com": "Tumblr", "youtube.com": "YouTube"]
        if let name = known[host] { return name }
        if let name = known.first(where: { host.hasSuffix("." + $0.key) })?.value { return name }
        let path = url.path
        if path.range(of: #"^/@[^/]+/\d+/?$"#, options: .regularExpression) != nil
            || path.range(of: #"^/users/[^/]+/statuses/\d+/?$"#, options: .regularExpression) != nil
            || host.contains("mastodon") || host.hasSuffix(".social") { return "Mastodon" }
        return host.isEmpty ? url.absoluteString : host
    }
}

public extension Post {
    /// Copies on other sites, one per link.
    var syndicatedCopies: [SyndicatedCopy] {
        var seen = Set<URL>()
        return (syndication ?? []).filter { seen.insert($0).inserted && $0 != url }.map(SyndicatedCopy.init)
    }

    /// The server's syndication targets this post has no copy on yet, judged by host or service name.
    func unsyndicated(_ targets: [SyndicationTarget]) -> [SyndicationTarget] {
        let copies = syndicatedCopies
        let hosts = Set(copies.compactMap { $0.url.host?.lowercased() })
        // Short names such as "X" would match too much, so those count by host only.
        let services = Set(copies.map { $0.service.lowercased() }.filter { $0.count >= 4 })
        return targets.filter { target in
            if let host = URL(string: target.uid)?.host?.lowercased(), hosts.contains(host) { return false }
            let words = (target.name + " " + target.uid).lowercased()
            return !services.contains { words.contains($0) }
        }
    }
}

public extension Payload {
    /// A Micropub update that asks the server to syndicate a published post to more targets.
    static func syndicate(_ url: URL, to targets: [String], preferences: Preferences = Preferences()) throws -> JSONValue {
        guard !targets.isEmpty else { throw QuillError("Choose where to syndicate.") }
        return .object(["action": .string("update"), "url": .string(url.absoluteString),
                        "add": .object([preferences.syndicationField: .array(targets.map(JSONValue.string))])])
    }
}

public extension GitHubRepository {
    /// The file on github.com. HEAD stands for the repository's default branch.
    func webURL(for path: String) -> URL? {
        let parts = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
        guard !parts.isEmpty else { return nil }
        return URL(string: "https://github.com/\(fullName)/blob/HEAD/" + parts.joined(separator: "/"))
    }
}

public extension DraftMirror {
    /// The Markdown file written for a draft, once one has been.
    func markdownPath(for id: UUID) -> String? {
        drafts[id.uuidString]?.files.keys.filter { $0.hasSuffix(".md") }.sorted().first
    }
}
