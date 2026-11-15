import Foundation

public enum Payload {
    private static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
    private static func nested(_ type: String, _ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": strings([type]), "properties": .object(properties)])
    }
    public static func validate(_ d: Draft) throws {
        func require(_ value: String, _ message: String) throws { if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw QuillError(message) } }
        switch d.kind {
        case .note: try require(d.content, "Write something before publishing.")
        case .photo: if d.attachments.isEmpty && (d.fields["photo-url"] ?? "").isEmpty { throw QuillError("Add a photo first.") }
        case .reply, .bookmark, .like, .repost: _ = try WebURL.parse(d.target)
        case .article: if d.attachments.isEmpty && (d.fields["photo-url"] ?? "").isEmpty { try require(d.content, "Add content before publishing.") }
        case .code: try require(d.content, "Add content before publishing.")
        case .event:
            try require(d.title, "Give the event a name."); try require(d.fields["start"] ?? "", "Choose an event start.")
            if let start = d.fields["start"], let end = d.fields["end"], !end.isEmpty, let s = ISO8601DateFormatter().date(from: start), let e = ISO8601DateFormatter().date(from: end), e < s { throw QuillError("The event end must follow its start.") }
        case .review:
            try require(d.fields["item-name"] ?? "", "Name the item you’re reviewing.")
            _ = try WebURL.parse(d.fields["item-url"] ?? "")
            guard let rating = Double(d.fields["rating"] ?? ""), (1...5).contains(rating) else { throw QuillError("Choose a rating from 1 to 5.") }
        case .weight:
            guard let value = Double(d.fields["weight"] ?? ""), value.isFinite, value > 0 else { throw QuillError("Enter a positive weight.") }
        case .exercise:
            try require(d.fields["activity"] ?? "", "Choose an activity.")
            guard let minutes = Double(d.fields["minutes"] ?? ""), minutes.isFinite, minutes > 0 else { throw QuillError("Enter a positive duration in minutes.") }
            if let hr = d.fields["heartrate"], !hr.isEmpty, Double(hr).map({ $0.isFinite && $0 > 0 }) != true { throw QuillError("Enter a positive heart rate.") }
        case .itinerary:
            guard !d.legs.isEmpty else { throw QuillError("Add at least one travel leg.") }
            for leg in d.legs {
                try require(leg.origin, "Enter each leg’s origin."); try require(leg.destination, "Enter each leg’s destination.")
                guard let depart = ISO8601DateFormatter().date(from: leg.departure), let arrive = ISO8601DateFormatter().date(from: leg.arrival), arrive >= depart else { throw QuillError("Enter valid departure and arrival times with time zone offsets, in travel order.") }
            }
        }
        if !d.published.isEmpty && ISO8601DateFormatter().date(from: d.published) == nil { throw QuillError("Enter a publication date with a time zone.") }
    }
    public static func create(_ d: Draft, preferences: Preferences = Preferences()) throws -> JSONValue {
        try validate(d)
        var p: [String: JSONValue] = [:]
        func put(_ key: String, _ value: String) { if !value.isEmpty { p[key] = strings([value]) } }
        put("name", d.title)
        let markdown = !d.isHTML && d.fields["p3k-content-type"] == "text/markdown" && Preferences.markdownKinds.contains(d.kind)
        let content = d.kind == .article ? (markdown ? articleMarkdown(d) : articleHTML(d)) : d.content
        if !content.isEmpty { p["content"] = .array([d.isHTML && preferences.htmlContent ? .object(["html": .string(content)]) : .string(content)]) }
        // Micropub defines plain text and HTML; Quill's p3k-content-type marks the text as Markdown.
        if markdown && !content.isEmpty { put("p3k-content-type", "text/markdown") }
        put("category", "")
        let tags = d.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !tags.isEmpty { p["category"] = strings(tags) }
        put(preferences.slugField, d.slug); put("visibility", d.visibility); put("p3k-channel", d.channel); put("location", d.location); put("published", d.published)
        if d.remoteDraft { put("post-status", "draft") }
        if (d.visibility.isEmpty || d.visibility == "public") && !d.syndication.isEmpty { p[preferences.syndicationField] = strings(d.syndication) }
        switch d.kind {
        case .reply: put("in-reply-to", d.target); put("rsvp", d.fields["rsvp"] ?? "")
        case .bookmark: put("bookmark-of", d.target)
        case .like: put("like-of", d.target)
        case .repost: put("repost-of", d.target)
        case .event:
            for key in ["start", "end", "p3k-content-type", "slides", "slides-embed", "video-link", "video-embed"] { put(key, d.fields[key] ?? "") }
            if let name = d.fields["conference-name"], !name.isEmpty {
                p["conference"] = .array([nested("h-event", ["name": strings([name]), "url": strings([d.fields["conference-url"] ?? ""])])])
            }
            if !(d.fields["place-name"] ?? "").isEmpty {
                var place: [String: JSONValue] = ["name": strings([d.fields["place-name"]!])]
                for key in ["street-address", "locality", "region", "country-name", "latitude", "longitude", "url"] { if let v = d.fields["place-" + key], !v.isEmpty { place[key] = strings([v]) } }
                p["location"] = .array([nested("h-card", place)])
            }
        case .review:
            p["item"] = .array([nested("h-product", ["name": strings([d.fields["item-name"] ?? ""]), "url": strings([d.fields["item-url"] ?? ""])])])
            p["rating"] = .array([.number(Double(d.fields["rating"] ?? "") ?? 1)])
            put("summary", d.fields["summary"] ?? "")
        case .itinerary:
            p["itinerary"] = .array(d.legs.map { leg in
                nested("h-leg", ["transit-type": strings([leg.transitType]), "operator": strings([leg.operatorName]), "number": strings([leg.number]), "origin": strings([leg.origin]), "destination": strings([leg.destination]), "departure": strings([leg.departure]), "arrival": strings([leg.arrival])])
            })
        case .code: put("p3k-content-type", "code/" + (d.fields["language"] ?? "text"))
        case .weight: p["weight"] = .array([nested("h-measure", ["num": .array([.number(Double(d.fields["weight"] ?? "") ?? 0)]), "unit": strings([preferences.weightUnit])])])
        case .exercise:
            var workout: [String: JSONValue] = ["activity": strings([d.fields["activity"] ?? ""]), "duration": .array([nested("h-measure", ["num": .array([.number((Double(d.fields["minutes"] ?? "") ?? 0) * 60)]), "unit": strings(["second"])])])]
            if let hr = Double(d.fields["heartrate"] ?? "") { workout["heartrate"] = .array([nested("h-measure", ["num": .array([.number(hr)]), "unit": strings(["bpm"])])]) }
            p["workout"] = .array([nested("h-workout", workout)])
        default: break
        }
        var photos: [JSONValue] = d.attachments.compactMap { attachment in
            guard let url = attachment.remoteURL else { return nil }
            return attachment.alt.isEmpty ? .string(url.absoluteString) : .object(["value": .string(url.absoluteString), "alt": .string(attachment.alt)])
        }
        if let external = d.fields["photo-url"], !external.isEmpty { _ = try WebURL.parse(external); photos.append(.string(external)) }
        if !photos.isEmpty && d.kind != .article { p["photo"] = .array(photos) }
        return nested(d.kind == .review ? "h-review" : (d.kind == .event ? "h-event" : "h-entry"), p)
    }
    public static func articleMarkdown(_ draft: Draft) -> String {
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ") }
        var images = draft.attachments.map { attachment in
            "![\(escape(attachment.alt))](\(attachment.remoteURL?.absoluteString ?? "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"))"
        }
        if let external = draft.fields["photo-url"], (try? WebURL.parse(external)) != nil { images.append("![](\(external))") }
        return ([draft.content.trimmingCharacters(in: .whitespacesAndNewlines)] + images).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    public static func articleHTML(_ draft: Draft) -> String {
        func escape(_ value: String) -> String { value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;") }
        var html = draft.content.replacingOccurrences(of:#"<img\b[^>]*quill-attachment:[^>]*>"#,with:"",options:[.regularExpression,.caseInsensitive])
        var images = draft.attachments.map { attachment -> String in
            let src = attachment.remoteURL?.absoluteString ?? "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
            return "<figure><img src=\"\(escape(src))\" alt=\"\(escape(attachment.alt))\"></figure>"
        }.joined()
        if let external = draft.fields["photo-url"], (try? WebURL.parse(external)) != nil { images += "<figure><img src=\"\(escape(external))\" alt=\"\"></figure>" }
        if let range = html.range(of:"</body>",options:.caseInsensitive) { html.insert(contentsOf:images,at:range.lowerBound) }
        else { html += images }
        return html
    }
    /// A Micropub update that replaces or deletes only the properties changed since the post was fetched.
    public static func update(_ d: Draft, preferences: Preferences = Preferences()) throws -> JSONValue {
        guard let url = d.editURL else { throw QuillError("No post URL to update.") }
        guard d.kind.isEditable else { throw QuillError("This post type does not support updating.") }
        if let key = d.kind.targetProperty { _ = try WebURL.parse(d.target); _ = key }
        let original = d.original ?? [:]
        var replace: [String: JSONValue] = [:], removed: [String] = []
        for (key, value) in d.editableValues.sorted(by: { $0.key < $1.key }) where value != (original[key] ?? "") {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { if !(original[key] ?? "").isEmpty { removed.append(key) }; continue }
            switch key {
            case "category":
                replace[key] = strings(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            case "content":
                if d.isHTML { replace[key] = .array([.object(["html": .string(value)])]) }
                else {
                    replace[key] = strings([value])
                    if d.kind == .code { replace["p3k-content-type"] = strings(["code/" + (d.fields["language"] ?? "text")]) }
                    else if let format = d.fields["p3k-content-type"], !format.isEmpty { replace["p3k-content-type"] = strings([format]) }
                }
            default: replace[key] = strings([value])
            }
        }
        guard !replace.isEmpty || !removed.isEmpty else { throw QuillError("Nothing has changed.") }
        var body: [String: JSONValue] = ["action": .string("update"), "url": .string(url.absoluteString)]
        if !replace.isEmpty { body["replace"] = .object(replace) }
        if !removed.isEmpty { body["delete"] = strings(removed) }
        return .object(body)
    }
}
