import Foundation

public enum Discovery {
    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }
    private static func splitHeader(_ value: String, separator: Character) -> [String] {
        var parts: [String] = [], current = ""
        var quote: Character?, escaped = false, angle = false
        for character in value {
            if escaped { escaped = false; current.append(character); continue }
            if let active = quote {
                current.append(character)
                if character == "\\" { escaped = true }
                else if character == active { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character }
            else if character == "<" { angle = true }
            else if character == ">" { angle = false }
            if character == separator && !angle { parts.append(current); current = "" }
            else { current.append(character) }
        }
        parts.append(current)
        return parts
    }
    public static func parse(html: String, linkHeader: String?, baseURL: URL) -> [String: URL] {
        var result: [String: URL] = [:]
        func insert(_ href: String, _ rel: String) {
            let href = href.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#38;", with: "&")
            guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL, ["http","https"].contains(url.scheme?.lowercased() ?? "") else { return }
            for key in rel.lowercased().split(whereSeparator: { $0.isWhitespace }) where result[String(key)] == nil { result[String(key)] = url }
        }
        // Header discovery takes precedence over HTML discovery.
        for segment in splitHeader(linkHeader ?? "", separator:",") {
            guard let link = matches(#"^\s*<([^>]+)>(.*)$"#,segment).first else { continue }
            for parameter in splitHeader(link[2],separator:";") {
                if let rel = matches(#"^\s*rel\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s]+))\s*$"#,parameter).first {
                    insert(link[1],rel[1...3].first(where: { !$0.isEmpty }) ?? "")
                }
            }
        }
        let cleanHTML = html.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        for tag in matches(#"<link\b[^>]*>"#, cleanHTML) {
            var attrs: [String: String] = [:]
            for attr in matches(#"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, tag[0]) { attrs[attr[1].lowercased()] = attr[2...4].first(where: { !$0.isEmpty }) ?? "" }
            if let href = attrs["href"], let rel = attrs["rel"] { insert(href, rel) }
        }
        return result
    }
}
public enum OAuth {
    public static func requestedScopes(supported: [String]?) -> String {
        let base = ["create","update","media"]
        guard let supported else { return base.joined(separator:" ") }
        return (base + ["draft","delete"]).filter { supported.contains($0) }.joined(separator:" ")
    }
    public static func callback(_ url: URL, expectedState: String, expectedIssuer: String? = nil) throws -> String {
        guard url.scheme == "quill-native", url.host == "oauth", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw QuillError("Unexpected sign-in callback.") }
        guard Set(items.map(\.name)).count == items.count else { throw QuillError("Sign-in returned duplicate parameters.") }
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard value("state") == expectedState else { throw QuillError("Sign-in state did not match. Please try again.") }
        if let expectedIssuer, value("iss") != expectedIssuer { throw QuillError("Sign-in returned an unexpected authorization server.") }
        if value("error") != nil { throw QuillError("Your site declined sign-in.") }
        guard let code = value("code"), !code.isEmpty else { throw QuillError("Sign-in returned no authorization code.") }
        return code
    }
}
public enum Form {
    public static func encode(_ values: [String: String]) -> Data { encodePairs(values.sorted(by: { $0.key < $1.key })) }
    public static func encodePairs(_ values: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.map { ($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").utf8)
    }
}
