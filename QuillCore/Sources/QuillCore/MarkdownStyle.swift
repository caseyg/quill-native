import Foundation
import Markdown

/// A stretch of Markdown source that the editor shows with formatting, in UTF-16 offsets.
public struct MarkdownSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(Int), quote, codeBlock
        case strong, emphasis, strikethrough, code, link
        /// Syntax such as `**`, `#` or `](url)`, shown faded.
        case marker
    }
    public var kind: Kind
    public var range: NSRange
    public init(_ kind: Kind, _ range: NSRange) { self.kind = kind; self.range = range }
}

/// Finds the formatting in Markdown source so it can be styled in place, leaving the text as it is.
public enum MarkdownStyle {
    public static func spans(in source: String) -> [MarkdownSpan] {
        guard !source.isEmpty else { return [] }
        var walker = Walker(source: source)
        walker.visit(Document(parsing: source))
        return walker.spans
    }
}

/// Turns swift-markdown's line and UTF-8 column positions into UTF-16 offsets.
private struct Locator {
    let lines: [Substring]
    let starts: [Int]
    let length: Int

    init(_ source: String) {
        var lines: [Substring] = [], starts: [Int] = [], offset = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(line); starts.append(offset); offset += line.utf16.count + 1
        }
        self.lines = lines; self.starts = starts; length = source.utf16.count
    }

    func offset(_ location: SourceLocation) -> Int {
        let line = location.line - 1
        guard line >= 0 else { return 0 }
        guard line < lines.count else { return length }
        let text = lines[line]
        let bytes = min(max(0, location.column - 1), text.utf8.count)
        let index = text.utf8.index(text.utf8.startIndex, offsetBy: bytes)
        return min(length, starts[line] + text.utf16.distance(from: text.startIndex, to: index))
    }

    func range(_ range: SourceRange?) -> NSRange? {
        guard let range else { return nil }
        let start = offset(range.lowerBound), end = offset(range.upperBound)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}

private struct Walker: MarkupWalker {
    let text: NSString
    let locator: Locator
    var spans: [MarkdownSpan] = []

    init(source: String) { text = source as NSString; locator = Locator(source) }

    private func range(_ markup: Markup) -> NSRange? { locator.range(markup.range) }

    /// The part of a node not covered by its children: the syntax around them.
    private mutating func markOutside(_ markup: Markup) {
        guard let outer = range(markup) else { return }
        let inner = markup.children.compactMap { range($0) }
        guard let first = inner.map(\.location).min(), let last = inner.map({ NSMaxRange($0) }).max() else {
            return spans.append(MarkdownSpan(.marker, outer))
        }
        mark(outer.location, first)
        mark(last, NSMaxRange(outer))
    }

    private mutating func mark(_ start: Int, _ end: Int) {
        if end > start { spans.append(MarkdownSpan(.marker, NSRange(location: start, length: end - start))) }
    }

    private mutating func styled(_ kind: MarkdownSpan.Kind, _ markup: Markup) {
        if let r = range(markup) { spans.append(MarkdownSpan(kind, r)) }
    }

    mutating func visitHeading(_ heading: Heading) {
        styled(.heading(heading.level), heading); markOutside(heading); descendInto(heading)
    }
    mutating func visitStrong(_ strong: Strong) { styled(.strong, strong); markOutside(strong); descendInto(strong) }
    mutating func visitEmphasis(_ emphasis: Emphasis) { styled(.emphasis, emphasis); markOutside(emphasis); descendInto(emphasis) }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) { styled(.strikethrough, strikethrough); markOutside(strikethrough); descendInto(strikethrough) }
    mutating func visitLink(_ link: Link) { styled(.link, link); markOutside(link); descendInto(link) }
    mutating func visitImage(_ image: Image) { styled(.link, image); markOutside(image) }
    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) { styled(.marker, thematicBreak) }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let r = range(inlineCode) else { return }
        spans.append(MarkdownSpan(.code, r))
        let source = text.substring(with: r)
        let ticks = source.prefix { $0 == "`" }.count
        if ticks > 0 && r.length >= ticks * 2 {
            mark(r.location, r.location + ticks)
            mark(NSMaxRange(r) - ticks, NSMaxRange(r))
        }
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let r = range(codeBlock) else { return }
        spans.append(MarkdownSpan(.codeBlock, r))
        // Fence lines (``` or ~~~) are syntax; indented code has none.
        var fences: [MarkdownSpan] = []
        text.enumerateSubstrings(in: r, options: .byLines) { line, lineRange, _, _ in
            let trimmed = line?.trimmingCharacters(in: .whitespaces) ?? ""
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fences.append(MarkdownSpan(.marker, lineRange)) }
        }
        spans += fences
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        if let r = range(blockQuote) {
            spans.append(MarkdownSpan(.quote, r))
            var markers: [MarkdownSpan] = []
            text.enumerateSubstrings(in: r, options: .byLines) { line, lineRange, _, _ in
                let leading = (line ?? "").prefix { $0 == " " || $0 == ">" }.utf16.count
                if leading > 0 { markers.append(MarkdownSpan(.marker, NSRange(location: lineRange.location, length: leading))) }
            }
            spans += markers
        }
        descendInto(blockQuote)
    }

    mutating func visitListItem(_ listItem: ListItem) {
        // The bullet or number, up to where the item's text starts.
        if let outer = range(listItem), let first = listItem.children.compactMap({ range($0) }).first {
            mark(outer.location, first.location)
        }
        descendInto(listItem)
    }
}
