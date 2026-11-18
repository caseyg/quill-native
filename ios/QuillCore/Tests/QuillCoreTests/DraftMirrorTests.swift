import XCTest
@testable import QuillCore

final class DraftMirrorTests: XCTestCase {
    private func note(_ content: String, title: String = "") -> Draft {
        var draft = Draft(kind: .note)
        draft.id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        draft.content = content; draft.title = title
        return draft
    }

    func testMarkdownHasQuotedFrontMatterAndBody() {
        var draft = note("Hello \"world\"\nSecond line", title: "A: title")
        draft.tags = "one, two"
        draft.fields = ["p3k-content-type": "text/markdown", "empty": ""]
        let markdown = DraftExport.markdown(draft)
        XCTAssertEqual(markdown, """
        ---
        type: note
        title: "A: title"
        tags: ["one", "two"]
        fields:
          "p3k-content-type": "text/markdown"
        ---

        Hello "world"
        Second line

        """)
    }

    func testPathsUseTitleOrKindAndShortID() {
        var draft = note("Body text that would otherwise rename the file")
        XCTAssertEqual(DraftExport.paths(draft, folder: "drafts").markdown, "drafts/note-abcdef12.md")
        draft.title = "Café Notes, Part 2!"
        XCTAssertEqual(DraftExport.paths(draft, folder: "").markdown, "cafe-notes-part-2-abcdef12.md")
        XCTAssertEqual(DraftMirror.normalize("/a//b/../ "), "a/b")
    }

    func testPlanWritesNewDraftThenNothingUntilItChanges() {
        var draft = note("First")
        draft.attachments = [Attachment(data: Data([1, 2]), filename: "photo.JPG", mimeType: "image/jpeg")]
        var mirror = DraftMirror(repository: "me/drafts", folder: "drafts")
        let steps = mirror.plan([draft])
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].writes.map(\.path).last, "drafts/note-abcdef12.md")
        XCTAssertTrue(steps[0].writes[0].path.hasPrefix("drafts/media/abcdef12-") && steps[0].writes[0].path.hasSuffix(".jpg"))
        for write in steps[0].writes { mirror.wrote(write.path, sha: "sha-" + write.path, for: draft.id) }
        mirror.finished(steps[0])
        XCTAssertEqual(mirror.plan([draft]), [])

        // An edit rewrites only the Markdown, not the photo.
        draft.content = "Second"
        let edit = mirror.plan([draft])
        XCTAssertEqual(edit.first?.writes.map(\.path), ["drafts/note-abcdef12.md"])
        XCTAssertEqual(edit.first?.removals.count, 0)
    }

    func testRenameAndDeleteRemoveOldFiles() {
        var draft = note("Words")
        var mirror = DraftMirror(repository: "me/drafts", folder: "")
        for step in mirror.plan([draft]) {
            for write in step.writes { mirror.wrote(write.path, sha: "old", for: draft.id) }
            mirror.finished(step)
        }
        draft.title = "Now titled"
        let rename = mirror.plan([draft])
        XCTAssertEqual(rename.first?.writes.map(\.path), ["now-titled-abcdef12.md"])
        XCTAssertEqual(rename.first?.removals.map(\.path), ["note-abcdef12.md"])

        let gone = mirror.plan([])
        XCTAssertEqual(gone.count, 1)
        XCTAssertTrue(gone[0].removesDraft)
        XCTAssertEqual(gone[0].removals.map(\.sha), ["old"])
        mirror.finished(gone[0])
        XCTAssertTrue(mirror.drafts.isEmpty)
    }

    func testRepositoryRequiresPushPermission() {
        let writable: JSONValue = .object(["full_name": .string("me/a"), "private": .bool(false), "permissions": .object(["push": .bool(true)])])
        let readOnly: JSONValue = .object(["full_name": .string("me/b"), "private": .bool(true), "permissions": .object(["push": .bool(false)])])
        XCTAssertEqual(GitHubRepository(api: writable), GitHubRepository(fullName: "me/a", isPrivate: false))
        XCTAssertNil(GitHubRepository(api: readOnly))
    }
}
