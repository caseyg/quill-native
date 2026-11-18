import Foundation

/// The social networks Quill can write syndication text for.
public enum SocialService: String, Codable, CaseIterable, Sendable {
    case bluesky, mastodon

    public var name: String { self == .bluesky ? "Bluesky" : "Mastodon" }
    /// The most a post can hold, as each network counts.
    public var limit: Int { self == .bluesky ? 300 : 500 }

    /// The network a syndication target posts to, from its service, user, name or uid.
    public init?(_ target: SyndicationTarget) {
        if let user = target.user, let service = SocialService(link: user) { self = service; return }
        let words = [target.service ?? "", target.name, target.uid].joined(separator: " ").lowercased()
        if words.contains("bluesky") || words.contains("bsky") { self = .bluesky }
        else if words.contains("mastodon") || URL(string: target.uid).map({ SocialAccount(link: $0)?.service == .mastodon }) == true { self = .mastodon }
        else { return nil }
    }

    init?(link: URL) {
        guard let account = SocialAccount(link: link) else { return nil }
        self = account.service
    }
}

/// Someone the person follows, offered when they type @.
public struct FollowedAccount: Codable, Equatable, Hashable, Sendable {
    public var service: SocialService
    /// A Bluesky handle such as `alice.bsky.social`, or a Mastodon address such as `alice@example.social`.
    public var handle: String
    public var name: String
    public init(service: SocialService, handle: String, name: String) { self.service = service; self.handle = handle; self.name = name }
}

/// The person's own account on a network, which their follows are read from.
public struct SocialAccount: Codable, Equatable, Hashable, Sendable {
    public var service: SocialService
    /// A Bluesky handle or DID, or a Mastodon username.
    public var handle: String
    /// The Mastodon instance, such as `https://social.example`.
    public var instance: URL?

    public init(service: SocialService, handle: String, instance: URL? = nil) { self.service = service; self.handle = handle; self.instance = instance }

    /// Reads a profile or post link: `bsky.app/profile/<handle>/…` or `https://<instance>/@<user>/…`.
    public init?(link: URL) {
        let parts = link.path.split(separator: "/").map(String.init)
        let host = link.host?.lowercased() ?? ""
        if host == "bsky.app", parts.count >= 2, parts[0] == "profile" {
            self.init(service: .bluesky, handle: parts[1])
        } else if let first = parts.first, first.hasPrefix("@"), first.count > 1, !first.dropFirst().contains("@"), !host.isEmpty,
                  let instance = URL(string: "https://" + host) {
            self.init(service: .mastodon, handle: String(first.dropFirst()), instance: instance)
        } else if parts.count >= 2, parts[0] == "users", !host.isEmpty, let instance = URL(string: "https://" + host) {
            self.init(service: .mastodon, handle: parts[1], instance: instance)
        } else {
            return nil
        }
    }

    /// The account most of a site's syndication links belong to, for servers that don't name it.
    public static func inferred(_ service: SocialService, from posts: [Post]) -> SocialAccount? {
        var counts: [SocialAccount: Int] = [:]
        for post in posts { for link in post.syndication ?? [] { if let account = SocialAccount(link: link), account.service == service { counts[account, default: 0] += 1 } } }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key.handle > $1.key.handle) }?.key
    }
}

public enum SocialText {
    /// Characters as the network counts them. Mastodon counts every link as 23 and a mention as its username.
    public static func count(_ text: String, for service: SocialService) -> Int {
        guard service == .mastodon else { return text.count }
        var counted = text.replacingOccurrences(of: #"https?://[^\s]+"#, with: String(repeating: "x", count: 23), options: .regularExpression)
        counted = counted.replacingOccurrences(of: #"@([\w.-]+)@[\w.-]+"#, with: "@$1", options: .regularExpression)
        return counted.count
    }

    /// The handle being typed just before the cursor, after an @.
    public static func mentionQuery(_ text: String, cursor: String.Index) -> (range: Range<String.Index>, query: String)? {
        func handleCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || "_.-@".contains(c) }
        var start = cursor
        while start > text.startIndex, handleCharacter(text[text.index(before: start)]) { start = text.index(before: start) }
        // The word must start with @, and stand on its own: an email address is not a mention.
        guard start < cursor, text[start] == "@" else { return nil }
        if start > text.startIndex {
            let ahead = text[text.index(before: start)]
            guard ahead.isWhitespace || "(—".contains(ahead) else { return nil }
        }
        return (start..<cursor, String(text[text.index(after: start)..<cursor]).lowercased())
    }

    /// Inserts a handle for the mention being typed, with a space after it.
    public static func insert(_ account: FollowedAccount, into text: String, replacing range: Range<String.Index>) -> (text: String, cursor: Int) {
        let spaced = range.upperBound < text.endIndex && text[range.upperBound].isWhitespace
        let replacement = "@" + account.handle + (spaced ? "" : " ")
        var result = text
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        result.replaceSubrange(range, with: replacement)
        return (result, offset + replacement.count + (spaced ? 1 : 0))
    }

    /// Followed accounts on one network that match what was typed, best first.
    public static func suggestions(_ query: String, in accounts: [FollowedAccount], service: SocialService, limit: Int = 8) -> [FollowedAccount] {
        let matches = accounts.filter { $0.service == service && (query.isEmpty || "\($0.handle) \($0.name)".lowercased().contains(query)) }
        return Array(matches.sorted { a, b in
            let x = a.handle.lowercased().hasPrefix(query), y = b.handle.lowercased().hasPrefix(query)
            return x != y ? x : a.handle.lowercased() < b.handle.lowercased()
        }.prefix(limit))
    }

    /// The post's title and text, shortened with an ellipsis to fit, then a link back to it.
    public static func defaultText(title: String, text: String, url: URL, service: SocialService) -> String {
        let link = url.absoluteString
        let source = [title, text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        var characters = Array(source)
        let original = characters.count
        while !characters.isEmpty {
            let body = String(characters).trimmingCharacters(in: .whitespacesAndNewlines) + (characters.count < original ? "…" : "")
            let candidate = body + "\n\n" + link
            if count(candidate, for: service) <= service.limit { return candidate }
            characters.removeLast()
        }
        return link
    }
}

/// Reads who the person follows, from each network's public API.
public enum SocialFollows {
    public typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static func fetch(_ account: SocialAccount, maxPages: Int = 50, fetch: Fetch = Network.send) async throws -> [FollowedAccount] {
        func json(_ url: URL) async throws -> (JSONValue, HTTPURLResponse) {
            var request = URLRequest(url: url); request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(request)
            guard (200..<300).contains(response.statusCode) else { throw QuillError("\(account.service.name) returned HTTP \(response.statusCode).", status: response.statusCode) }
            return (try JSONDecoder().decode(JSONValue.self, from: data), response)
        }
        var accounts: [FollowedAccount] = []
        switch account.service {
        case .bluesky:
            var cursor: String?
            var seen = Set<String>()
            for _ in 0..<maxPages {
                var c = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.graph.getFollows")!
                c.queryItems = [URLQueryItem(name: "actor", value: account.handle), URLQueryItem(name: "limit", value: "100")] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
                let (page, _) = try await json(c.url!)
                for follow in page.object?["follows"]?.array ?? [] {
                    guard let o = follow.object, let handle = o["handle"]?.string, handle != "handle.invalid" else { continue }
                    let name = o["displayName"]?.string ?? ""
                    accounts.append(FollowedAccount(service: .bluesky, handle: handle, name: name.isEmpty ? handle : name))
                }
                guard let next = page.object?["cursor"]?.string, !next.isEmpty, seen.insert(next).inserted else { break }
                cursor = next
            }
        case .mastodon:
            guard let instance = account.instance, let host = instance.host, instance.scheme == "https" else { throw QuillError("No Mastodon instance.") }
            var lookup = URLComponents(url: instance.appendingPathComponent("api/v1/accounts/lookup"), resolvingAgainstBaseURL: false)!
            lookup.queryItems = [URLQueryItem(name: "acct", value: account.handle)]
            guard let id = try await json(lookup.url!).0.object?["id"]?.string else { throw QuillError("Mastodon didn’t find @\(account.handle).") }
            var next: URL? = instance.appendingPathComponent("api/v1/accounts/\(id)/following").appending(queryItems: [URLQueryItem(name: "limit", value: "80")])
            var seen = Set<URL>()
            while let url = next, url.host == host, seen.insert(url).inserted, seen.count <= maxPages {
                let (page, response) = try await json(url)
                for follow in page.array ?? [] {
                    guard let o = follow.object, let acct = o["acct"]?.string else { continue }
                    let name = o["display_name"]?.string ?? ""
                    accounts.append(FollowedAccount(service: .mastodon, handle: acct.contains("@") ? acct : "\(acct)@\(host)", name: name.isEmpty ? acct : name))
                }
                next = response.value(forHTTPHeaderField: "Link").flatMap(nextLink)
            }
        }
        var unique = Set<String>()
        return accounts.filter { unique.insert($0.handle.lowercased()).inserted }.sorted { $0.handle.lowercased() < $1.handle.lowercased() }
    }

    static func nextLink(_ header: String) -> URL? {
        for part in header.split(separator: ",") where part.contains(#"rel="next""#) {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else { continue }
            return URL(string: String(part[part.index(after: start)..<end]))
        }
        return nil
    }
}

/// Followed accounts kept on device, so mentions work offline and the networks are asked at most daily.
public struct FollowCache: Codable, Equatable, Sendable {
    public var accounts: [FollowedAccount] = []
    /// When each account's follows were last read, keyed by `service:handle`.
    public var updated: [String: Date] = [:]
    public init() {}

    public static func key(_ account: SocialAccount) -> String { "\(account.service.rawValue):\(account.handle.lowercased())" }

    public func isFresh(_ account: SocialAccount, now: Date = Date()) -> Bool {
        updated[FollowCache.key(account)].map { now.timeIntervalSince($0) < 86_400 } ?? false
    }

    public mutating func store(_ follows: [FollowedAccount], for account: SocialAccount, now: Date = Date()) {
        accounts.removeAll { $0.service == account.service }
        accounts += follows
        updated[FollowCache.key(account)] = now
    }
}
