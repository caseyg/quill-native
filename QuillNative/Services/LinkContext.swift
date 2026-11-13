import Foundation
import QuillCore

struct LinkContext {
    let title: String
    let description: String
    static func fetch(_ url: URL) async throws -> LinkContext {
        var request = URLRequest(url:url); request.timeoutInterval = 15
        let (data,response) = try await Network.send(request); try Network.check(response)
        guard data.count < 5_000_000 else { throw QuillError("This page is too large to preview.") }
        let html = String(decoding:data,as:UTF8.self)
        func extract(_ pattern: String) -> String {
            guard let regex = try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive,.dotMatchesLineSeparators]), let match = regex.firstMatch(in:html,range:NSRange(html.startIndex...,in:html)), let range = Range(match.range(at:1),in:html) else { return "" }
            return String(html[range]).replacingOccurrences(of:"&amp;",with:"&").replacingOccurrences(of:"&quot;",with:"\"").replacingOccurrences(of:#"<[^>]+>"#,with:"",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        let title = extract(#"<title[^>]*>(.*?)</title>"#)
        let description = extract(#"<meta[^>]*(?:name|property)=["'](?:description|og:description)["'][^>]*content=["']([^"']*)["']"#)
        return LinkContext(title:title.isEmpty ? (url.host ?? url.absoluteString) : title,description:description)
    }
}
