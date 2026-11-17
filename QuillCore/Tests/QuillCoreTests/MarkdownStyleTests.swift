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

    func testPlainTextHasNoSpans() {
        XCTAssertEqual(MarkdownStyle.spans(in: "Just words.\nMore words."), [])
        XCTAssertEqual(MarkdownStyle.spans(in: ""), [])
    }
}
