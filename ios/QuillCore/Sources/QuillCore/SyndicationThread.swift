import Foundation

/// A server's support for sending a post's social copy as a thread, from `syndication-thread` in `q=config`.
/// https://github.com/caseyg/caseyagollan.com/blob/main/docs/indieweb-publishing/proposals/micropub-syndication-threads.md
public struct ThreadSupport: Codable, Equatable, Sendable {
    /// The post property that holds the thread.
    public var property = "syndication-thread"
    /// The post property that places photos on posts of the thread.
    public var photoProperty = "syndication-photo-post"
    public var maxPosts = 20
    public var maxPhotosPerPost = 4
    /// Characters per post on each network the server names, keyed by network, such as "bluesky".
    public var limits: [String: Int] = [:]

    public init() {}

    init?(_ value: JSONValue?) {
        guard let o = value?.object else { return nil }
        func number(_ v: JSONValue?) -> Int? { if case .number(let n)? = v, n.isFinite, n > 0 { return Int(n) }; return nil }
        if let p = o["property"]?.string, !p.isEmpty { property = p }
        if let p = o["photo-property"]?.string, !p.isEmpty { photoProperty = p }
        maxPosts = max(1, number(o["max-posts"]) ?? maxPosts)
        maxPhotosPerPost = number(o["max-photos-per-post"]) ?? maxPhotosPerPost
        for (key, limit) in o["limits"]?.object ?? [:] { if let characters = number(limit.object?["characters"]) { limits[key.lowercased()] = characters } }
    }

    /// The most one post can hold on a network, as the server says, else the network's own limit.
    public func limit(for service: SocialService) -> Int { limits[service.rawValue] ?? service.limit }
}

public enum ThreadSplitter {
    /// Splits text into posts that each fit `fits`, at paragraphs, then sentences, then words.
    /// A link back, when given, ends the last post, or becomes a post of its own when it doesn't fit.
    public static func split(_ text: String, link: String? = nil, fits: (String) -> Bool) -> [String] {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var posts = source.isEmpty ? [] : pack(source, level: 0, fits: fits)
        if let link, !link.isEmpty {
            if let last = posts.last, fits(last + "\n\n" + link) { posts[posts.count - 1] = last + "\n\n" + link }
            else { posts.append(link) }
        }
        return posts
    }

    private static let separators = ["\n\n", " ", " "]

    /// Units of text at one level: paragraphs, sentences, words.
    private static func units(_ text: String, level: Int) -> [String] {
        let pieces: [String]
        switch level {
        case 0: pieces = text.replacingOccurrences(of: #"\n[ \t]*\n\s*"#, with: "\n\n", options: .regularExpression).components(separatedBy: "\n\n")
        case 1: pieces = sentences(text)
        default: pieces = text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in if let sentence { result.append(sentence) } }
        return result.isEmpty ? [text] : result
    }

    private static func pack(_ text: String, level: Int, fits: (String) -> Bool) -> [String] {
        if fits(text) { return [text] }
        guard level < 3 else { return hardSplit(text, fits: fits) }
        let separator = separators[level]
        var posts: [String] = []
        var current = ""
        for unit in units(text, level: level) {
            let joined = current.isEmpty ? unit : current + separator + unit
            if fits(joined) { current = joined; continue }
            if !current.isEmpty { posts.append(current); current = "" }
            if fits(unit) { current = unit }
            else {
                var pieces = pack(unit, level: level + 1, fits: fits)
                current = pieces.popLast() ?? ""
                posts += pieces
            }
        }
        if !current.isEmpty { posts.append(current) }
        return posts
    }

    /// A word longer than a post, cut by characters.
    private static func hardSplit(_ text: String, fits: (String) -> Bool) -> [String] {
        var posts: [String] = []
        var current = ""
        for character in text {
            if fits(current + String(character)) { current.append(character) }
            else { if !current.isEmpty { posts.append(current) }; current = String(character) }
        }
        if !current.isEmpty { posts.append(current) }
        return posts
    }
}

public extension Payload {
    /// Syndicates a published post as a thread: the thread is saved on the post, then sent to the targets.
    static func syndicate(_ url: URL, to targets: [String], thread: [String], support: ThreadSupport, preferences: Preferences = Preferences()) throws -> JSONValue {
        guard !targets.isEmpty else { throw QuillError("Choose where to syndicate.") }
        let posts = thread.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard posts.count > 1, posts.allSatisfy({ !$0.isEmpty }) else { throw QuillError("Every post of the thread needs text.") }
        guard posts.count <= support.maxPosts else { throw QuillError("A thread can have at most \(support.maxPosts) posts.") }
        return .object(["action": .string("update"), "url": .string(url.absoluteString),
                        preferences.syndicationField: .array(targets.map(JSONValue.string)),
                        "replace": .object([support.property: .array(posts.map(JSONValue.string))])])
    }
}
