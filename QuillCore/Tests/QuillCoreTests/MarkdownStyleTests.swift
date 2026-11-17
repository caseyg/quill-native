import XCTest
@testable import QuillCore

final class MarkdownStyleTests: XCTestCase {
    private func text(_ source: String, _ kind: MarkdownSpan.Kind) -> [String] {
        MarkdownStyle.spans(in: source).filter { $0.kind == kind }.map { (source as NSString).substring(with: $0.range) }
    }

    func testBoldAndItalicMarkTheirDelimiters() {
        let source = "Some **bold** and *soft* words"
        XCTAssertEqual(text(source, .strong), ["**bold**"])
        XCTAssertEqual(text(source, .emphasis), ["*soft*"])
        XCTAssertEqual(text(source, .marker), ["**", "**", "*", "*"])
    }

    func testHeadingMarksItsHashes() {
        let source = "Intro\n\n## A heading\n\nBody"
        XCTAssertEqual(text(source, .heading(2)), ["## A heading"])
        XCTAssertEqual(text(source, .marker), ["## "])
    }

    func testLinkFadesItsAddress() {
        let source = "See [the post](https://example.com/a) now"
        XCTAssertEqual(text(source, .link), ["[the post](https://example.com/a)"])
        XCTAssertEqual(text(source, .marker), ["[", "](https://example.com/a)"])
    }

    func testCodeQuotesAndLists() {
        let source = "> quoted\n\n- item\n\nUse `code` here\n\n```\nlet x = 1\n```"
        XCTAssertEqual(text(source, .quote), ["> quoted"])
        XCTAssertEqual(text(source, .code), ["`code`"])
        XCTAssertEqual(text(source, .codeBlock).count, 1)
        XCTAssertEqual(text(source, .marker), ["> ", "- ", "`", "`", "```", "```"])
    }

    func testOffsetsCountUTF16AfterEmoji() {
        let source = "😀 café **bold**"
        XCTAssertEqual(text(source, .strong), ["**bold**"])
    }

    /// cmark gives inline columns on a paragraph's later lines as if they were indented like its first,
    /// which is wrong for lazy lines after a list item or quote, and for indented continuation lines.
    func testLaterLinesOfAParagraphKeepTheirOwnIndent() {
        for (source, marks) in [
            ("- item\n**strong** x", ["- ", "**", "**"]),
            ("> quote\n**strong** x", ["> ", "**", "**"]),
            ("> quote\n>   **strong** x", ["> ", ">   ", "**", "**"]),
            ("para\n  **x**", ["**", "**"]),
            ("1. a\n   b **c**\nlazy **d**", ["1. ", "**", "**", "**", "**"]),
            ("  - x\n    - y\n**z**", ["- ", "- ", "**", "**"]),
            ("- item\n**strong*soft [site](https://a.example/)***", ["- ", "**", "*", "[", "](https://a.example/)", "*", "**"]),
        ] {
            XCTAssertEqual(text(source, .marker).sorted(), marks.sorted(), source)
        }
        XCTAssertEqual(text("- item\nlazy **bold** end", .strong), ["**bold**"])
        XCTAssertEqual(text("- item\nsee [it](https://a.example/)", .link), ["[it](https://a.example/)"])
    }

    /// cmark gives emphasis that closes together with its parent the parent's end; the markers stay apart.
    func testNestedEmphasisClosingTogether() {
        XCTAssertEqual(text("**a*b***", .emphasis), ["*b*"])
        XCTAssertEqual(text("**a*b***", .marker).sorted(), ["*", "*", "**", "**"])
        XCTAssertEqual(text("***a***", .strong), ["**a**"])
        XCTAssertEqual(text("***a***", .marker).sorted(), ["*", "*", "**", "**"])
        XCTAssertEqual(text("*a **b***", .strong), ["**b**"])
        XCTAssertEqual(text("~~gone~~ and ~one~", .strikethrough), ["~~gone~~", "~one~"])
        XCTAssertEqual(text("~~gone~~ and ~one~", .marker), ["~~", "~~", "~", "~"])
    }

    func testPlainTextHasNoSpans() {
        XCTAssertEqual(MarkdownStyle.spans(in: "Just words.\nMore words."), [])
        XCTAssertEqual(MarkdownStyle.spans(in: ""), [])
    }
}
