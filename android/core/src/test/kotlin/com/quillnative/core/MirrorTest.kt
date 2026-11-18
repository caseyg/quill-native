package com.quillnative.core

import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MirrorTest {
    private fun note(content: String, title: String = "") = Draft(id = "ABCDEF12-0000-0000-0000-000000000000", kind = PostKind.NOTE, content = content, title = title)

    @Test fun markdownHasQuotedFrontMatterAndBody() {
        val draft = note("Hello \"world\"\nSecond line", "A: title").copy(tags = "one, two", fields = mapOf("p3k-content-type" to "text/markdown", "empty" to ""))
        assertEquals("---\ntype: note\ntitle: \"A: title\"\ntags: [\"one\", \"two\"]\nfields:\n  \"p3k-content-type\": \"text/markdown\"\n---\n\nHello \"world\"\nSecond line\n",
            DraftExport.markdown(draft))
    }

    @Test fun pathsUseTitleOrKindAndShortId() {
        val draft = note("Body text that would otherwise rename the file")
        assertEquals("drafts/note-abcdef12.md", DraftExport.paths(draft, "drafts").markdown)
        assertEquals("cafe-notes-part-2-abcdef12.md", DraftExport.paths(draft.copy(title = "Café Notes, Part 2!"), "").markdown)
        assertEquals("a/b", DraftMirror.normalize("/a//b/../ "))
    }

    @Test fun planWritesNewDraftThenNothingUntilItChanges() {
        var draft = note("First").copy(attachments = listOf(Attachment(data = byteArrayOf(1, 2), filename = "photo.JPG", mimeType = "image/jpeg")))
        var mirror = DraftMirror.create("me/drafts", "drafts")
        val steps = mirror.plan(listOf(draft))
        assertEquals(1, steps.size)
        assertEquals("drafts/note-abcdef12.md", steps[0].writes.last().first)
        assertTrue(steps[0].writes[0].first.startsWith("drafts/media/abcdef12-") && steps[0].writes[0].first.endsWith(".jpg"))
        for ((path, _) in steps[0].writes) mirror = mirror.wrote(path, "sha-$path", draft.id)
        mirror = mirror.finished(steps[0])
        assertTrue(mirror.plan(listOf(draft)).isEmpty())
        draft = draft.copy(content = "Second")
        val edit = mirror.plan(listOf(draft))
        assertEquals(listOf("drafts/note-abcdef12.md"), edit[0].writes.map { it.first })
        assertEquals(0, edit[0].removals.size)
    }

    @Test fun renameAndDeleteRemoveOldFiles() {
        var draft = note("Words")
        var mirror = DraftMirror.create("me/drafts", "")
        for (step in mirror.plan(listOf(draft))) {
            for ((path, _) in step.writes) mirror = mirror.wrote(path, "old", draft.id)
            mirror = mirror.finished(step)
        }
        draft = draft.copy(title = "Now titled")
        val rename = mirror.plan(listOf(draft))
        assertEquals(listOf("now-titled-abcdef12.md"), rename[0].writes.map { it.first })
        assertEquals(listOf("note-abcdef12.md"), rename[0].removals.map { it.first })
        val gone = mirror.plan(emptyList())
        assertEquals(1, gone.size)
        assertTrue(gone[0].removesDraft)
        assertEquals(listOf("old"), gone[0].removals.map { it.second })
        assertTrue(mirror.finished(gone[0]).drafts.isEmpty())
    }

    @Test fun repositoryRequiresPushPermission() {
        val writable = obj("full_name" to JsonPrimitive("me/a"), "private" to JsonPrimitive(false), "permissions" to obj("push" to JsonPrimitive(true)))
        val readOnly = obj("full_name" to JsonPrimitive("me/b"), "private" to JsonPrimitive(true), "permissions" to obj("push" to JsonPrimitive(false)))
        assertEquals(GitHubRepository("me/a", false), GitHubRepository.fromApi(writable))
        assertNull(GitHubRepository.fromApi(readOnly))
    }

    @Test fun deviceFlowWaitsForApproval() {
        var polls = 0
        val flow = GitHubDeviceFlow(Transport { req ->
            if (req.url.endsWith("/device/code")) ok(req, """{"device_code":"d","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","interval":0,"expires_in":900}""")
            else if (++polls < 2) ok(req, """{"error":"authorization_pending"}""") else ok(req, """{"access_token":"gho_x","token_type":"bearer"}""")
        })
        val code = blocking { flow.start("client") }
        assertEquals("ABCD-1234", code.userCode)
        assertEquals("gho_x", blocking { flow.token("client", code.copy(interval = 0)) })
    }
}
