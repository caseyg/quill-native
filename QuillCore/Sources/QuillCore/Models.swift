import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

public enum PostKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case note, photo, reply, article, bookmark, like, repost, event, review, itinerary, code, weight, exercise
    public var id: String { rawValue }
    public var title: String { switch self {
        case .like: return "Like"
        default: return rawValue.capitalized
    } }
    public var symbol: String { switch self {
        case .note: return "square.and.pencil"
        case .photo: return "photo"
        case .reply: return "arrowshape.turn.up.left"
        case .article: return "doc.richtext"
        case .bookmark: return "bookmark"
        case .like: return "heart"
        case .repost: return "arrow.2.squarepath"
        case .event: return "calendar"
        case .review: return "star"
        case .itinerary: return "airplane"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .weight: return "scalemass"
        case .exercise: return "figure.run"
    } }
}

public struct Attachment: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var data: Data
    public var filename: String
    public var mimeType: String
    public var alt: String
    public var remoteURL: URL?
    public init(data: Data, filename: String, mimeType: String, alt: String = "") {
        self.data = data; self.filename = filename; self.mimeType = mimeType; self.alt = alt
    }
}
public struct Leg: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var transitType = "air"
    public var operatorName = ""
    public var number = ""
    public var origin: String
    public var destination: String
    public var departure: String
    public var arrival: String
    public init(origin: String = "", destination: String = "", departure: String = "", arrival: String = "") {
        self.origin = origin; self.destination = destination; self.departure = departure; self.arrival = arrival
    }
}
public struct Draft: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: PostKind
    public var title = ""
    public var content = ""
    public var isHTML = false
    public var target = ""
    public var tags = ""
    public var slug = ""
    public var visibility = ""
    public var channel = ""
    public var syndication: [String] = []
    public var location = ""
    public var published: String = ""
    public var remoteDraft = false
    public var fields: [String: String] = [:]
    public var legs: [Leg] = []
    public var attachments: [Attachment] = []
    public var editURL: URL?
    /// The edited properties as they were fetched, so an update sends only what changed.
    public var original: [String: String]?
    public var accountURL: URL?
    public var modified = Date()
    public init(kind: PostKind) { self.kind = kind }
    /// The title, else the body, else a photo description, else the link it responds to.
    public var displayTitle: String {
        let body = isHTML ? HTML.text(content) : content
        for value in [title, body, attachments.first(where: { !$0.alt.isEmpty })?.alt ?? "", target] {
            let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { return String(line.prefix(80)) }
        }
        return "Untitled \(kind.title)"
    }
    /// True when nothing worth keeping has been entered, so closing the composer leaves no draft behind.
    public var isBlank: Bool {
        func empty(_ value: String) -> Bool { value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        let defaults: Set<String> = ["rating","start","p3k-content-type"]
        return editURL == nil && attachments.isEmpty && [title,content,target,tags,location].allSatisfy(empty)
            && fields.allSatisfy { defaults.contains($0.key) || empty($0.value) }
            && legs.allSatisfy { [$0.origin,$0.destination,$0.operatorName,$0.number].allSatisfy(empty) }
    }
}
public struct Preferences: Codable, Equatable, Sendable {
    public var slugField = "mp-slug"
    public var syndicationField = "mp-syndicate-to"
    public var htmlContent = true
    public var weightUnit = "lb"
    /// Write posts as Markdown, marked with `p3k-content-type: text/markdown`, instead of HTML.
    public var markdown = false
    /// Post types left out of the new-post menu and the post list.
    public var hiddenKinds: [PostKind] = []
    public init() {}
    public init(from decoder: Decoder) throws {
        // Every key is optional so settings saved by older versions still load.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        slugField = try c.decodeIfPresent(String.self, forKey: .slugField) ?? d.slugField
        syndicationField = try c.decodeIfPresent(String.self, forKey: .syndicationField) ?? d.syndicationField
        htmlContent = try c.decodeIfPresent(Bool.self, forKey: .htmlContent) ?? d.htmlContent
        weightUnit = try c.decodeIfPresent(String.self, forKey: .weightUnit) ?? d.weightUnit
        markdown = try c.decodeIfPresent(Bool.self, forKey: .markdown) ?? d.markdown
        hiddenKinds = (try? c.decodeIfPresent([PostKind].self, forKey: .hiddenKinds)) ?? d.hiddenKinds
    }
    public var visibleKinds: [PostKind] { PostKind.allCases.filter { !hiddenKinds.contains($0) } }
    /// Kinds whose body can be written as Markdown.
    public static let markdownKinds: [PostKind] = [.note, .photo, .reply, .article, .bookmark]
}
public struct Account: Codable, Equatable, Sendable {
    public var me: URL
    public var micropub: URL
    public var tokenEndpoint: URL?
    public var scope: String
    public init(me: URL, micropub: URL, tokenEndpoint: URL? = nil, scope: String = "create update media") {
        self.me = me; self.micropub = micropub; self.tokenEndpoint = tokenEndpoint; self.scope = scope
    }
    public func permits(_ action: String) -> Bool { scope.split(separator: " ").contains(Substring(action)) }
}
public struct Receipt: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var title: String
    public var kind: PostKind
    public var url: URL
    public var date = Date()
    public var accountURL: URL?
    public var status: String
    public init(draft: Draft, url: URL, now: Date = Date()) {
        title = draft.displayTitle; kind = draft.kind; self.url = url; accountURL = draft.accountURL
        status = draft.editURL != nil ? "Updated" : (draft.remoteDraft ? "Draft" : ((ISO8601DateFormatter().date(from:draft.published).map { $0 > now } ?? false) ? "Scheduled" : "Published"))
    }
}
public struct QuillError: LocalizedError, Equatable {
    public let message: String
    /// The HTTP status, when the error came from a server response.
    public var status: Int?
    public init(_ message: String, status: Int? = nil) { self.message = message; self.status = status }
    public var errorDescription: String? { message }
}
public enum WebURL {
    public static func parse(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw QuillError("Enter a valid http or https URL.") }
        return url
    }
    public static func site(_ value: String) throws -> URL {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where:\.isWhitespace) else { throw QuillError("Enter a valid http or https URL.") }
        let url = try parse(input.contains("://") ? input : "https://" + input)
        var c = URLComponents(url:url,resolvingAgainstBaseURL:false)!
        if c.path.isEmpty { c.path = "/" }
        return c.url!
    }
}

public extension Draft {
    mutating func setPublicationDateEnabled(_ enabled: Bool, now: Date = Date()) {
        if !enabled { published = "" }
        else if published.isEmpty { published = ISO8601DateFormatter().string(from:now) }
    }
}
