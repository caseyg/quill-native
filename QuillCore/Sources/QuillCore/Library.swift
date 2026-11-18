import Foundation

/// A published post as the app keeps it on device for listing and search.
public struct Post: Codable, Identifiable, Equatable, Sendable {
    public var url: URL
    public var kind: PostKind
    public var name = ""
    /// Plain text of the content, for display and search.
    public var text = ""
    public var target = ""
    public var categories: [String] = []
    public var photo: URL?
    public var photoAlt = ""
    public var published: Date?
    public var isDraft = false
    /// Who wrote the post this one responds to, such as "Erin Kissane (@kissane.bsky.social)".
    public var citeAuthor: String?
    /// The text of the post this one responds to.
    public var citeText: String?
    /// Copies of the post on other sites, such as Bluesky or Mastodon, from its `syndication` property.
    /// Optional so libraries saved before it was kept still load.
    public var syndication: [URL]?
    /// The social copy as a thread, from `syndication-thread`, for servers that store one.
    public var thread: [String]?
    public var id: String { url.absoluteString }

    /// True until the responded-to page has been read. A page with nothing to show leaves empty strings.
    public var needsCite: Bool { !target.isEmpty && citeAuthor == nil && citeText == nil }

    public init(url: URL, kind: PostKind) { self.url = url; self.kind = kind }

    /// The name, else the body, else the photo description, else the link it responds to.
    public var displayTitle: String {
        for value in [name, text, photoAlt, citeText ?? "", citeAuthor ?? "", target] {
            let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { return String(line.prefix(200)) }
        }
        return url.path == "/" ? url.absoluteString : url.path
    }

    public func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = ([name, text, photoAlt, target, citeAuthor ?? "", citeText ?? "", url.absoluteString] + categories).joined(separator: "\n")
        return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public extension Post {
    /// Reads a microformats2 object, such as an item from `q=source` or a `q=source&url=` response.
    init?(mf2 value: JSONValue, url fallback: URL? = nil) {
        guard let p = value.object?["properties"]?.object else { return nil }
        let type = value.object?["type"]?.array?.first?.string ?? "h-entry"
        guard let url = (p["url"]?.array?.first?.string).flatMap({ try? WebURL.parse($0) }) ?? fallback else { return nil }
        self.init(url: url, kind: PostKind.discover(type: type, properties: p))
        let content = MF2.content(p["content"])
        name = MF2.text(p["name"])
        text = MF2.text(p["p3k-content-type"]) == "text/markdown" ? Markdown.text(content.text) : content.text
        if name.trimmingCharacters(in: .whitespacesAndNewlines) == text.prefix(name.count).trimmingCharacters(in: .whitespacesAndNewlines) && kind != .article { name = "" }
        target = ["in-reply-to", "bookmark-of", "like-of", "repost-of"].lazy.compactMap { MF2.url(p[$0]) }.first ?? ""
        // Servers may describe the target as an h-cite with its author and text.
        if let cite = ["in-reply-to", "bookmark-of", "like-of", "repost-of"].lazy.compactMap({ p[$0]?.array?.first?.object?["properties"]?.object }).first {
            let author = MF2.text(cite["author"]), quoted = MF2.content(cite["content"]).text, title = MF2.text(cite["name"])
            if !author.isEmpty { citeAuthor = author }
            if !quoted.isEmpty || !title.isEmpty { citeText = quoted.isEmpty ? title : quoted }
        }
        categories = (p["category"]?.array ?? []).compactMap { $0.string }
        if let photo = p["photo"]?.array?.first {
            let raw = photo.string ?? photo.object?["value"]?.string ?? photo.object?["url"]?.string
            // Servers may store photos as paths relative to the post.
            self.photo = raw.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }.flatMap { try? WebURL.parse($0.absoluteString) }
            photoAlt = photo.object?["alt"]?.string ?? ""
        } else if let image = content.image {
            photo = image.url; photoAlt = image.alt
        }
        published = MF2.text(p["published"]).isEmpty ? nil : MF2.date(MF2.text(p["published"]))
        isDraft = MF2.text(p["post-status"]) == "draft" || p["draft"]?.array?.first == .bool(true)
        let copies = (p["syndication"]?.array ?? []).compactMap { $0.string ?? $0.object?["value"]?.string ?? $0.object?["properties"]?.object?["url"]?.array?.first?.string }
            .compactMap { try? WebURL.parse($0) }
        syndication = copies.isEmpty ? nil : copies
        let posts = (p["syndication-thread"]?.array ?? []).compactMap(\.string).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        thread = posts.count > 1 ? posts : nil
    }
}

public extension PostKind {
    /// Post type discovery, close to the IndieWeb algorithm, extended for Quill's types.
    static func discover(type: String, properties p: [String: JSONValue]) -> PostKind {
        if type == "h-event" { return .event }
        if type == "h-review" { return .review }
        if p["itinerary"] != nil { return .itinerary }
        if p["workout"] != nil { return .exercise }
        if p["weight"] != nil { return .weight }
        if p["like-of"] != nil { return .like }
        if p["repost-of"] != nil { return .repost }
        if p["bookmark-of"] != nil { return .bookmark }
        if p["in-reply-to"] != nil { return .reply }
        if MF2.text(p["p3k-content-type"]).hasPrefix("code/") { return .code }
        if p["photo"] != nil { return .photo }
        let name = MF2.text(p["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let content = MF2.content(p["content"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && !content.hasPrefix(name) { return .article }
        return .note
    }

    /// Kinds the composer can edit in place. Structured posts are edited on the site.
    var isEditable: Bool { [.note, .photo, .reply, .article, .bookmark, .like, .repost, .code].contains(self) }
}

/// Small helpers for reading microformats2 JSON.
public enum MF2 {
    public static func text(_ value: JSONValue?) -> String {
        guard let first = value?.array?.first ?? value else { return "" }
        if let s = first.string { return s }
        if let o = first.object { return o["value"]?.string ?? o["html"]?.string.map(HTML.text) ?? o["properties"]?.object?["name"].map { text($0) } ?? "" }
        return ""
    }
    static func url(_ value: JSONValue?) -> String? {
        guard let first = value?.array?.first else { return nil }
        return first.string ?? first.object?["properties"]?.object?["url"]?.array?.first?.string ?? first.object?["value"]?.string
    }
    /// Content as text, with HTML source when the server sent HTML.
    public static func content(_ value: JSONValue?) -> (text: String, html: String?, image: (url: URL, alt: String)?) {
        guard let first = value?.array?.first else { return ("", nil, nil) }
        if let s = first.string { return (s, nil, nil) }
        guard let o = first.object else { return ("", nil, nil) }
        let html = o["html"]?.string
        return (o["value"]?.string ?? html.map(HTML.text) ?? "", html, html.flatMap(HTML.firstImage))
    }
    public static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }
        // Some servers omit the "T" or the time zone.
        let fallback = DateFormatter(); fallback.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            fallback.dateFormat = format
            if let date = fallback.date(from: value) { return date }
        }
        return nil
    }
}

public enum Markdown {
    /// Readable text of Markdown source, for rows and search.
    public static func text(_ source: String) -> String {
        var s = source
        s = s.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__|\*|`)"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum HTML {
    /// Visible text of an HTML fragment, with block elements as line breaks.
    public static func text(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6]|/blockquote|/figure)\b[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: character)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// True when the HTML is only paragraphs and line breaks, so plain text loses nothing.
    public static func isPlain(_ html: String) -> Bool {
        html.range(of: #"<(?!/?(p|br)\b)[a-z/!]"#, options: [.regularExpression, .caseInsensitive]) == nil
    }
    static func firstImage(_ html: String) -> (url: URL, alt: String)? {
        guard let tag = html.range(of: #"<img\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]).map({ String(html[$0]) }) else { return nil }
        func attribute(_ name: String) -> String? {
            guard let r = tag.range(of: name + #"\s*=\s*("[^"]*"|'[^']*')"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let raw = tag[r].split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
            return text(String(raw.dropFirst().dropLast()))
        }
        guard let src = attribute("src"), let url = try? WebURL.parse(src) else { return nil }
        return (url, attribute("alt") ?? "")
    }
}

// MARK: Listing

public enum LibrarySource: String, Codable, Sendable {
    /// Every post, from the Micropub `q=source` list.
    case micropub
    /// Recent posts only, from the site's feed.
    case feed
}

public struct PostPage: Sendable {
    public var posts: [Post]
    public var after: String?
}

public extension MicropubClient {
    /// One page of the Micropub `q=source` list. Returns nil when the server doesn't offer listing.
    func posts(limit: Int = 100, after: String? = nil) async throws -> PostPage? {
        var parameters = ["limit": String(limit)]
        if let after { parameters["after"] = after }
        let data: Data
        do { data = try await query("source", parameters: parameters) }
        catch let error as QuillError where error.status.map({ [400, 404, 405, 422, 501].contains($0) }) ?? false { return nil }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let items = value.object?["items"]?.array else { return nil }
        let after = value.object?["paging"]?.object?["after"]?.string
        return PostPage(posts: items.compactMap { Post(mf2: $0) }, after: after?.isEmpty == false ? after : nil)
    }
}

public enum Feed {
    /// Feed links in a page, best first: JSON Feed, then Atom, then RSS.
    public static func links(html: String, baseURL: URL) -> [URL] {
        let ranked = ["application/feed+json": 0, "application/json": 1, "application/atom+xml": 2, "application/rss+xml": 3]
        var found: [(Int, URL)] = []
        guard let regex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            func attribute(_ name: String) -> String? {
                guard let r = tag.range(of: #"\b"# + name + #"\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
                return tag[r].split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
            guard attribute("rel")?.lowercased().split(separator: " ").contains("alternate") == true,
                  let rank = ranked[attribute("type")?.lowercased() ?? ""],
                  let href = attribute("href"), let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: baseURL)?.absoluteURL,
                  !found.contains(where: { $0.1 == url }) else { continue }
            found.append((rank, url))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Posts in a JSON Feed, Atom or RSS document, and the next page for JSON Feed.
    public static func parse(_ data: Data) -> (posts: [Post], next: URL?) {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data), let feed = value.object {
            let posts: [Post] = (feed["items"]?.array ?? []).compactMap { item in
                guard let o = item.object, let raw = o["url"]?.string ?? o["id"]?.string, let url = try? WebURL.parse(raw) else { return nil }
                return post(url: url, title: o["title"]?.string, html: o["content_html"]?.string, text: o["content_text"]?.string ?? o["summary"]?.string,
                            image: o["image"]?.string, date: o["date_published"]?.string, tags: (o["tags"]?.array ?? []).compactMap(\.string))
            }
            return (posts, feed["next_url"]?.string.flatMap { try? WebURL.parse($0) })
        }
        let reader = XMLFeedReader(); let parser = XMLParser(data: data); parser.delegate = reader; parser.parse()
        return (reader.entries.compactMap { e in
            guard let url = (e["link"] ?? e["guid"]).flatMap({ try? WebURL.parse($0) }) else { return nil }
            return post(url: url, title: e["title"], html: e["content"] ?? e["description"] ?? e["summary"], text: nil, image: nil, date: e["published"] ?? e["pubDate"] ?? e["updated"], tags: e["category"].map { [$0] } ?? [])
        }, nil)
    }

    private static func post(url: URL, title: String?, html: String?, text: String?, image: String?, date: String?, tags: [String]) -> Post {
        let body = html.map(HTML.text) ?? text ?? ""
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let picture = html.flatMap(HTML.firstImage)
        var post = Post(url: url, kind: !name.isEmpty && !body.hasPrefix(name) ? .article : (picture != nil || image != nil ? .photo : .note))
        post.name = post.kind == .article ? name : ""
        post.text = body
        post.photo = image.flatMap { try? WebURL.parse($0) } ?? picture?.url
        post.photoAlt = picture?.alt ?? ""
        post.categories = tags
        post.published = date.flatMap { MF2.date($0) ?? rfc822($0) }
        return post
    }

    private static func rfc822(_ value: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.date(from: value)
    }
}

/// Collects `<item>` and `<entry>` fields from RSS and Atom.
private final class XMLFeedReader: NSObject, XMLParserDelegate {
    var entries: [[String: String]] = []
    private var current: [String: String]?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" || name == "entry" { current = [:] }
        else if current != nil, name == "link", let href = attributes["href"], attributes["rel"] == nil || attributes["rel"] == "alternate" { current?["link"] = href }
        else if current != nil, name == "category", let term = attributes["term"] { current?["category"] = term }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item" || name == "entry" { if let current { entries.append(current) }; current = nil; return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = name.replacingOccurrences(of: "content:encoded", with: "content")
        if current != nil, !value.isEmpty, current?[key] == nil { current?[key] = value }
    }
}

// MARK: Responded-to pages

public enum PageSummary {
    /// The author and text a page shares in its Open Graph tags, as Bluesky and Mastodon posts do.
    public static func parse(html: String) -> (author: String, text: String) {
        func meta(_ name: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive) else { return nil }
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: match.range)
                func attribute(_ key: String) -> String? {
                    guard let r = tag.range(of: #"\b"# + key + #"\s*=\s*("[^"]*"|'[^']*')"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
                    return String(tag[r].split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces).dropFirst().dropLast())
                }
                if [attribute("property"), attribute("name")].contains(where: { $0?.lowercased() == name }), let content = attribute("content") {
                    return HTML.text(content)
                }
            }
            return nil
        }
        var title = meta("og:title") ?? ""
        if title.isEmpty, let r = html.range(of: #"<title[^>]*>[^<]*"#, options: [.regularExpression, .caseInsensitive]) {
            title = HTML.text(String(html[r]).replacingOccurrences(of: #"<title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive]))
        }
        return (title, meta("og:description") ?? meta("description") ?? "")
    }
}

public extension Post {
    /// The author's display name, without the handle Bluesky and Mastodon add in parentheses.
    var citeName: String? {
        guard let author = citeAuthor?.trimmingCharacters(in: .whitespaces), !author.isEmpty else { return nil }
        return author.replacingOccurrences(of: #"\s*\(@[^)]*\)$"#, with: "", options: .regularExpression)
    }
}

// MARK: Sync and storage

public struct Library: Codable, Equatable, Sendable {
    public var posts: [Post] = []
    public var source: LibrarySource?
    public var synced: Date?
    /// False while a first download has not reached the oldest post. Libraries saved before this was kept were complete.
    public var complete: Bool?
    public init() {}

    /// Whether a refresh only needs posts newer than the ones on device.
    public var isComplete: Bool { complete ?? (synced != nil) }

    /// Newest first. Posts without a date keep the server's order at the end.
    /// `keeping` holds on to posts the fetch did not include, for a feed or a refresh that stopped at known posts.
    public mutating func replace(with posts: [Post], source: LibrarySource, keeping: Bool = false, complete: Bool = true, now: Date = Date()) {
        var seen = Set<String>()
        let known = Dictionary(self.posts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var merged = posts.filter { seen.insert($0.id).inserted }.map { post in
            // Keep what was read from the responded-to page, which the server doesn't send.
            guard post.needsCite, let old = known[post.id], old.target == post.target else { return post }
            var post = post; post.citeAuthor = old.citeAuthor; post.citeText = old.citeText; return post
        }
        // A feed shows only recent posts, so keep older ones already on device.
        if source == .feed || keeping { merged += self.posts.filter { seen.insert($0.id).inserted } }
        self.posts = merged.enumerated().sorted { a, b in
            switch (a.element.published, b.element.published) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        self.source = source; synced = now; self.complete = complete
    }

    /// Replaces a post in place, or adds a new one at the top.
    public mutating func upsert(_ post: Post) {
        if let index = posts.firstIndex(where: { $0.id == post.id }) { posts[index] = post }
        else { posts.insert(post, at: 0) }
    }

    public func search(_ query: String) -> [Post] { posts.filter { $0.matches(query) } }
}

public struct LibraryStore: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }
    public func load() -> Library {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Library.self, from: $0) } ?? Library()
    }
    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: file, options: .atomic)
    }
    public func delete() { try? FileManager.default.removeItem(at: file) }
}

public enum LibrarySync {
    public typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Every post from Micropub when the server lists them, otherwise recent posts from the site's feed.
    /// `progress` receives each page as it arrives, so a list can fill in while the rest downloads.
    public static func fetch(client: MicropubClient, me: URL, maxPages: Int = 200, known: Set<String> = [], fetch: @escaping Fetch = Network.send, progress: @escaping @Sendable ([Post]) async -> Void = { _ in }) async throws -> (posts: [Post], source: LibrarySource, finished: Bool) {
        /// Pages run newest first, so a page with a post already on device means the rest are too.
        func reachesKnown(_ page: [Post]) -> Bool { !known.isEmpty && page.contains { known.contains($0.id) } }
        if var page = try await client.posts() {
            var posts = page.posts
            await progress(page.posts)
            var cursors = Set<String>()
            var finished = true
            if !reachesKnown(page.posts) {
                finished = false
                for _ in 1..<maxPages {
                    guard let after = page.after, cursors.insert(after).inserted, !page.posts.isEmpty else { finished = true; break }
                    guard let next = try await client.posts(after: after) else { finished = true; break }
                    page = next; posts += next.posts
                    await progress(next.posts)
                    if reachesKnown(next.posts) { finished = true; break }
                }
            }
            return (posts, .micropub, finished)
        }
        let (html, response) = try await fetch(URLRequest(url: me)); try Network.check(response)
        guard let feedURL = Feed.links(html: String(decoding: html, as: UTF8.self), baseURL: response.url ?? me).first else {
            throw QuillError("Your site doesn’t list its posts.")
        }
        var posts: [Post] = []
        var next: URL? = feedURL
        var visited = Set<URL>()
        while let url = next, visited.insert(url).inserted, visited.count <= maxPages {
            let (data, response) = try await fetch(URLRequest(url: url)); try Network.check(response)
            let page = Feed.parse(data)
            posts += page.posts; next = page.next
            await progress(page.posts)
            if reachesKnown(page.posts) { next = nil }
        }
        return (posts, .feed, next == nil || visited.contains(next!))
    }
}

// MARK: Editing

public extension Draft {
    /// A draft for editing a post, from its `q=source` properties.
    init(source value: JSONValue, url: URL) throws {
        guard let p = value.object?["properties"]?.object else { throw QuillError("The source response contains no properties.") }
        let type = value.object?["type"]?.array?.first?.string ?? "h-entry"
        let kind = PostKind.discover(type: type, properties: p)
        guard kind.isEditable else { throw QuillError("\(kind.title) posts can’t be edited here yet.") }
        self.init(kind: kind)
        editURL = url
        title = MF2.text(p["name"])
        let content = MF2.content(p["content"])
        if let html = content.html, kind == .article || !HTML.isPlain(html) {
            self.content = html; isHTML = true
        } else {
            self.content = content.html.map(HTML.text) ?? content.text
        }
        if kind != .article && kind != .code && !title.isEmpty && self.content.hasPrefix(title) { title = "" }
        if let key = kind.targetProperty { target = MF2.url(p[key]) ?? "" }
        tags = (p["category"]?.array ?? []).compactMap(\.string).joined(separator: ", ")
        let format = MF2.text(p["p3k-content-type"])
        if kind == .code { fields["language"] = format.replacingOccurrences(of: "code/", with: "") }
        else if !format.isEmpty { fields["p3k-content-type"] = format }
        published = MF2.text(p["published"])
        if kind.hasPhotoProperty {
            attachments = (p["photo"]?.array ?? []).compactMap { value in
                guard let link = value.string ?? value.object?["value"]?.string, let url = URL(string: link) else { return nil }
                var photo = Attachment(data: Data(), filename: url.lastPathComponent, mimeType: "image/jpeg", alt: value.object?["alt"]?.string ?? "")
                photo.remoteURL = url
                return photo
            }
        }
        original = editableValues
    }

    /// Uploaded photos as the `photo` property: a URL, or a URL with its description.
    var photoProperty: [JSONValue] {
        attachments.compactMap { attachment in
            guard !attachment.isAudio, let url = attachment.remoteURL else { return nil }
            return attachment.alt.isEmpty ? .string(url.absoluteString) : .object(["value": .string(url.absoluteString), "alt": .string(attachment.alt)])
        }
    }

    /// The values an update compares against the post as fetched.
    var editableValues: [String: String] {
        var values = ["name": title, "category": tags]
        if kind.targetProperty == nil || kind.hasEditableText { values["content"] = content }
        if let key = kind.targetProperty { values[key] = target }
        // Photos compare in order, so a reordered or redescribed photo counts as a change.
        if kind.hasPhotoProperty {
            values["photo"] = attachments.filter { !$0.isAudio }.map { "\($0.remoteURL?.absoluteString ?? $0.id.uuidString)\u{1F}\($0.alt)" }.joined(separator: "\n")
        }
        return values
    }
}

extension PostKind {
    var targetProperty: String? {
        switch self {
        case .reply: return "in-reply-to"
        case .bookmark: return "bookmark-of"
        case .like: return "like-of"
        case .repost: return "repost-of"
        default: return nil
        }
    }
    var hasEditableText: Bool { [.reply, .bookmark].contains(self) }
    /// Kinds whose photos are a `photo` property; an article's sit in its content instead.
    public var hasPhotoProperty: Bool { [.note, .photo, .reply, .bookmark].contains(self) }
}
