import Foundation
import QuillCore

/// What a web page says about itself: its title, summary, preview image and tags.
struct LinkContext: Equatable {
    let title: String
    let description: String
    var image: URL? = nil
    var tags: [String] = []

    static func fetch(_ url: URL) async throws -> LinkContext {
        var request = URLRequest(url:url); request.timeoutInterval = 15
        let (data,response) = try await Network.send(request); try Network.check(response)
        guard data.count < 5_000_000 else { throw QuillError("This page is too large to preview.") }
        return parse(html: String(decoding:data,as:UTF8.self), url: response.url ?? url)
    }

    static func parse(html: String, url: URL) -> LinkContext {
        let meta = metaTags(html)
        func first(_ keys: String...) -> String { keys.lazy.compactMap { meta[$0]?.first(where: { !$0.isEmpty }) }.first ?? "" }
        let title = first("og:title", "twitter:title").isEmpty ? match(#"<title[^>]*>(.*?)</title>"#, in: html) : first("og:title", "twitter:title")
        let image = URL(string: first("og:image", "og:image:url", "twitter:image"), relativeTo: url)?.absoluteURL
        var tags: [String] = []
        for value in (meta["article:tag"] ?? []) + (meta["keywords"] ?? []).flatMap({ $0.split(separator: ",").map(String.init) }) {
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty, tag.count <= 40, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
        }
        return LinkContext(
            title: title.isEmpty ? (url.host ?? url.absoluteString) : title,
            description: first("og:description", "description", "twitter:description"),
            image: image.flatMap { try? WebURL.parse($0.absoluteString) },
            tags: Array(tags.prefix(10))
        )
    }

    /// `<meta>` values by `property` or `name`, lowercased, in page order.
    private static func metaTags(_ html: String) -> [String: [String]] {
        guard let tag = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive),
              let attribute = try? NSRegularExpression(pattern: #"([a-zA-Z:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return [:] }
        var result: [String: [String]] = [:]
        for found in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(found.range, in: html) else { continue }
            let element = String(html[range])
            var values: [String: String] = [:]
            for pair in attribute.matches(in: element, range: NSRange(element.startIndex..., in: element)) {
                guard let name = Range(pair.range(at: 1), in: element) else { continue }
                let value = Range(pair.range(at: 2), in: element) ?? Range(pair.range(at: 3), in: element)
                values[element[name].lowercased()] = value.map { decode(String(element[$0])) } ?? ""
            }
            guard let key = values["property"] ?? values["name"], let content = values["content"] else { continue }
            result[key.lowercased(), default: []].append(content)
        }
        return result
    }

    private static func match(_ pattern: String, in html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive,.dotMatchesLineSeparators]), let found = regex.firstMatch(in:html,range:NSRange(html.startIndex...,in:html)), let range = Range(found.range(at:1),in:html) else { return "" }
        return decode(String(html[range]).replacingOccurrences(of:#"<[^>]+>"#,with:"",options:.regularExpression))
    }

    private static func decode(_ value: String) -> String {
        var text = value
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
