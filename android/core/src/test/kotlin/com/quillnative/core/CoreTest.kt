package com.quillnative.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.time.Instant

class CoreTest {
    private fun props(d: Draft, prefs: Preferences = Preferences()) = Payload.create(d, prefs)["properties"].obj!!

    @Test fun privateVisibilityCannotSyndicate() {
        val p = props(Draft(kind = PostKind.NOTE, content = "Private words", visibility = "private", syndication = listOf("https://social.example/")))
        assertNull(p["mp-syndicate-to"])
        assertEquals(strings("private"), p["visibility"])
    }

    @Test fun bookmarkSendsTitleSummaryNoteAndTags() {
        val p = props(Draft(kind = PostKind.BOOKMARK, target = "https://example.com/article", title = "An Article", content = "Why I saved it.",
            tags = "reading, web", fields = mapOf("summary" to "What the page says about itself.")))
        assertEquals(strings("https://example.com/article"), p["bookmark-of"])
        assertEquals(strings("An Article"), p["name"])
        assertEquals(strings("What the page says about itself."), p["summary"])
        assertEquals(strings("Why I saved it."), p["content"])
        assertEquals(strings("reading", "web"), p["category"])
    }

    @Test fun workoutUsesSecondsAndNestedMeasures() {
        val p = props(Draft(kind = PostKind.EXERCISE, fields = mapOf("activity" to "running", "minutes" to "25", "heartrate" to "132")))
        val workout = p["workout"].arr!![0].obj!!["properties"].obj!!
        assertEquals("[1500]", workout["duration"].arr!![0].obj!!["properties"].obj!!["num"].toString())
    }

    @Test fun itineraryRetainsIndependentTimeZones() {
        val leg = Leg(origin = "JFK", destination = "LHR", departure = "2026-12-01T20:00:00-05:00", arrival = "2026-12-02T08:00:00+00:00")
        val legs = props(Draft(kind = PostKind.ITINERARY, legs = listOf(leg)))["itinerary"].arr!!
        assertEquals(strings("h-leg"), legs[0].obj!!["type"])
        assertEquals(strings(leg.arrival), legs[0].obj!!["properties"].obj!!["arrival"])
    }

    @Test fun reviewIsHReviewWithProduct() {
        val body = Payload.create(Draft(kind = PostKind.REVIEW, fields = mapOf("item-name" to "Book", "item-url" to "https://example.com/book", "rating" to "4")))
        assertEquals(strings("h-review"), body["type"])
        assertEquals(strings("h-product"), body["properties"].obj!!["item"].arr!![0].obj!!["type"])
    }

    @Test fun blankAndMalformedTargetsAreRejected() {
        assertFails<QuillException> { Payload.create(Draft(kind = PostKind.NOTE)) }
        assertFails<QuillException> { Payload.create(Draft(kind = PostKind.LIKE, target = "javascript:alert(1)")) }
    }

    @Test fun rsvpAndLegacyFieldNames() {
        val p = props(Draft(kind = PostKind.REPLY, content = "See you", target = "https://example.com/event", fields = mapOf("rsvp" to "yes"), slug = "party"),
            Preferences(slugField = "slug"))
        assertEquals(strings("yes"), p["rsvp"])
        assertEquals(strings("party"), p["slug"])
    }

    @Test fun draftAndAttachmentRoundTripAndDelete() {
        val root = Files.createTempDirectory("drafts").toFile()
        try {
            val store = DraftStore(root)
            val draft = Draft(kind = PostKind.PHOTO, content = "Image", attachments = listOf(Attachment(data = byteArrayOf(0, 1, 2), filename = "photo.jpg", mimeType = "image/jpeg", alt = "A tree")))
            store.save(draft)
            val loaded = store.load()
            assertTrue(loaded[0].attachments[0].data.contentEquals(byteArrayOf(0, 1, 2)))
            assertEquals(draft.id, loaded[0].id)
            assertEquals(draft, loaded[0])
            store.delete(draft.id)
            assertTrue(store.load().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun enablingPublicationDatePreservesSavedDate() {
        val d = Draft(kind = PostKind.NOTE, published = "2030-12-01T12:00:00-05:00").withPublicationDate(true)
        assertEquals("2030-12-01T12:00:00-05:00", d.published)
        assertEquals("", d.withPublicationDate(false).published)
        assertTrue(Draft(kind = PostKind.NOTE).withPublicationDate(true, Instant.parse("2026-01-02T03:04:05Z")).published == "2026-01-02T03:04:05Z")
    }

    @Test fun receiptComparesInstantsAcrossOffsets() {
        val d = Draft(kind = PostKind.NOTE, content = "Hello", published = "2026-11-13T20:00:00+14:00")
        assertEquals("Published", Receipt.of(d, "https://example.com/1", Instant.parse("2026-11-13T15:00:00Z")).status)
    }

    @Test fun articleMediaUsesCurrentAltAndRemovesDeletedImageTokens() {
        val photo = Attachment(data = byteArrayOf(1, 2), filename = "photo.jpg", mimeType = "image/jpeg", alt = "Two <trees>", remoteURL = "https://example.com/photo.jpg")
        val d = Draft(kind = PostKind.ARTICLE, isHTML = true, content = "<p>A story</p><img src=\"quill-attachment:deleted\">", attachments = listOf(photo))
        val html = props(d)["content"].arr!![0].obj!!["html"].str!!
        assertTrue(html.contains("https://example.com/photo.jpg"))
        assertTrue(html.contains("Two &lt;trees&gt;"))
        assertFalse(html.contains("quill-attachment:"))
    }

    @Test fun blankDraftsAreNotWorthKeeping() {
        assertTrue(Draft(kind = PostKind.REVIEW, fields = mapOf("rating" to "5")).isBlank)
        assertTrue(Draft(kind = PostKind.ITINERARY, legs = listOf(Leg(departure = "2030-01-01T00:00:00Z"))).isBlank)
        assertTrue(Draft(kind = PostKind.NOTE, content = "  \n").isBlank)
        assertFalse(Draft(kind = PostKind.NOTE, content = "Hello").isBlank)
        assertFalse(Draft(kind = PostKind.LIKE, target = "https://example.com/post").isBlank)
    }

    @Test fun canonicalSiteAddsRootPath() {
        assertEquals("https://example.com/", WebUrl.site("example.com"))
        assertEquals("https://example.com/a?b=1", WebUrl.site("https://example.com/a?b=1"))
        assertFails<QuillException> { WebUrl.site("not a site") }
    }

    @Test fun everyKindProducesExpectedVocabulary() {
        val expected = mapOf(PostKind.NOTE to "content", PostKind.PHOTO to "photo", PostKind.REPLY to "in-reply-to", PostKind.ARTICLE to "content",
            PostKind.BOOKMARK to "bookmark-of", PostKind.LIKE to "like-of", PostKind.REPOST to "repost-of", PostKind.EVENT to "start", PostKind.REVIEW to "item",
            PostKind.ITINERARY to "itinerary", PostKind.CODE to "p3k-content-type", PostKind.WEIGHT to "weight", PostKind.EXERCISE to "workout")
        for (kind in PostKind.entries) {
            val d = Draft(kind = kind, content = "Test content", title = "Test title", target = "https://example.com/post",
                fields = mapOf("photo-url" to "https://example.com/photo.jpg", "start" to "2030-01-01T12:00:00Z", "item-name" to "A book",
                    "item-url" to "https://example.com/book", "rating" to "5", "weight" to "140", "activity" to "running", "minutes" to "20"),
                legs = listOf(Leg(origin = "JFK", destination = "LHR", departure = "2030-01-01T12:00:00Z", arrival = "2030-01-01T20:00:00Z")))
            assertNotNull(kind.raw, props(d)[expected[kind]!!])
        }
    }

    @Test fun legacyArticleRepresentationRetainsAttachedImages() {
        val d = Draft(kind = PostKind.ARTICLE, content = "<p>Story</p>", isHTML = true, attachments = listOf(Attachment(data = byteArrayOf(1), filename = "a.jpg", mimeType = "image/jpeg")))
        assertTrue(props(d, Preferences(htmlContent = false))["content"].arr!![0].str!!.contains("data:image/jpeg;base64,AQ=="))
    }

    @Test fun photoOnlyArticleAndExternalPhotoAreIncluded() {
        val d = Draft(kind = PostKind.ARTICLE, isHTML = true, fields = mapOf("photo-url" to "https://example.com/photo.jpg"))
        assertTrue(props(d)["content"].arr!![0].obj!!["html"].str!!.contains("https://example.com/photo.jpg"))
    }

    @Test fun savedJsonUsesSwiftCompatibleNames() {
        val json = QuillJson.encodeToString(Draft.serializer(), Draft(id = "X", kind = PostKind.ARTICLE, modified = 0))
        assertTrue(json, json.contains("\"kind\":\"article\""))
        assertEquals(PostKind.ARTICLE, QuillJson.decodeFromString(Draft.serializer(), json).kind)
    }
}
