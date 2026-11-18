package com.quillnative.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryTest {
    private val endpoint = "https://example.com/micropub"

    @Test fun listingFollowsPagingUntilTheEnd() {
        val client = MicropubClient(endpoint, "t", Transport { req ->
            assertEquals("source", query(req.url)["q"])
            if ("after" in query(req.url)) ok(req, """{"items":[{"type":["h-entry"],"properties":{"url":["https://example.com/2"],"content":["Second"],"published":["2026-11-01T10:00:00Z"]}}]}""")
            else ok(req, """{"items":[{"type":["h-entry"],"properties":{"url":["https://example.com/1"],"name":["Hello"],"content":[{"html":"<p>Body</p>","value":"Body"}],"published":["2026-11-02T10:00:00Z"]}}],"paging":{"after":"abc"}}""")
        })
        val result = blocking { LibrarySync.fetch(client, "https://example.com/") }
        assertEquals(LibrarySource.micropub, result.source)
        assertEquals(listOf("https://example.com/1", "https://example.com/2"), result.posts.map { it.url })
        assertEquals(PostKind.ARTICLE, result.posts[0].kind)
        assertEquals(PostKind.NOTE, result.posts[1].kind)
    }

    @Test fun refreshStopsAtPostsAlreadyOnDevice() {
        var pages = 0
        val client = MicropubClient(endpoint, "t", Transport { req ->
            pages++
            val n = query(req.url)["after"]?.toInt() ?: 0
            ok(req, """{"items":[{"type":["h-entry"],"properties":{"url":["https://example.com/$n"],"content":["Post $n"]}}],"paging":{"after":"${n + 1}"}}""")
        })
        val result = blocking { LibrarySync.fetch(client, "https://example.com/", known = setOf("https://example.com/2")) }
        assertEquals(listOf("https://example.com/0", "https://example.com/1", "https://example.com/2"), result.posts.map { it.url })
        assertTrue(result.finished)
        assertEquals(3, pages)
    }

    @Test fun refreshKeepsOlderPostsAndCompletion() {
        var library = Library().replacing(listOf(Post("https://example.com/old", PostKind.NOTE)), LibrarySource.micropub, complete = false)
        assertFalse(library.isComplete)
        library = library.replacing(listOf(Post("https://example.com/new", PostKind.NOTE, published = System.currentTimeMillis())), LibrarySource.micropub, keeping = true)
        assertEquals(listOf("https://example.com/new", "https://example.com/old"), library.posts.map { it.url })
        assertTrue(library.isComplete)
    }

    @Test fun librariesSavedBeforeCompletionWasKeptCountAsComplete() {
        assertTrue(QuillJson.decodeFromString(Library.serializer(), """{"posts":[],"synced":0}""").isComplete)
        assertFalse(Library().isComplete)
    }

    @Test fun fallsBackToJsonFeedWhenListingIsUnsupported() {
        val client = MicropubClient(endpoint, "t", Transport { ok(it, """{"error":"invalid_request"}""", 400) })
        val result = blocking {
            LibrarySync.fetch(client, "https://example.com/", transport = Transport { req ->
                if (path(req.url) == "/") ok(req, """<link rel="alternate" type="application/rss+xml" href="/feed.xml"><link rel="alternate" type="application/feed+json" href="/feed.json">""")
                else {
                    assertEquals("/feed.json", path(req.url))
                    ok(req, """{"version":"https://jsonfeed.org/version/1.1","items":[{"id":"1","url":"https://example.com/p/1","content_html":"<p><img src=\"https://example.com/a.jpg\" alt=\"A heron\"></p>","date_published":"2026-11-15T15:30:53.000Z"}]}""")
                }
            })
        }
        assertEquals(LibrarySource.feed, result.source)
        assertEquals(PostKind.PHOTO, result.posts[0].kind)
        assertEquals("https://example.com/a.jpg", result.posts[0].photo)
        assertEquals("A heron", result.posts[0].displayTitle)
        assertNotNull(result.posts[0].published)
    }

    @Test fun rssEntriesParse() {
        val rss = "<rss><channel><item><title>Post</title><link>https://example.com/a</link><description><![CDATA[<p>Words here</p>]]></description><pubDate>Sat, 14 Nov 2026 20:24:13 +0000</pubDate></item></channel></rss>"
        val posts = Feed.parse(rss).posts
        assertEquals("https://example.com/a", posts[0].url)
        assertEquals("Words here", posts[0].text)
        assertNotNull(posts[0].published)
    }

    @Test fun atomEntriesParse() {
        val atom = """<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Hi</title><link rel="alternate" href="https://example.com/b"/><content type="html">&lt;p&gt;Hi there&lt;/p&gt;</content><updated>2026-11-14T20:24:13Z</updated></entry></feed>"""
        val posts = Feed.parse(atom).posts
        assertEquals("https://example.com/b", posts[0].url)
        assertEquals("Hi there", posts[0].text)
    }

    @Test fun photoPostsUseBodyThenAltForTitle() {
        val item = obj("type" to strings("h-entry"), "properties" to obj(
            "url" to strings("https://example.com/p"),
            "photo" to kotlinx.serialization.json.JsonArray(listOf(obj("value" to kotlinx.serialization.json.JsonPrimitive("https://example.com/p.jpg"), "alt" to kotlinx.serialization.json.JsonPrimitive("Sunset over the river")))),
        ))
        val post = Post.fromMf2(item)!!
        assertEquals(PostKind.PHOTO, post.kind)
        assertEquals("Sunset over the river", post.displayTitle)
        assertEquals("A dog", Draft(kind = PostKind.PHOTO, attachments = listOf(Attachment(data = ByteArray(0), filename = "a.jpg", mimeType = "image/jpeg", alt = "A dog"))).displayTitle)
    }

    @Test fun searchMatchesEveryTermAcrossFields() {
        val post = Post("https://example.com/1", PostKind.NOTE, text = "Walked to the café", categories = listOf("brooklyn"))
        assertTrue(post.matches("cafe brooklyn"))
        assertFalse(post.matches("cafe queens"))
    }

    @Test fun feedSyncKeepsOlderPostsAndSortsNewestFirst() {
        val old = Post("https://example.com/old", PostKind.NOTE, published = 1000)
        val new = Post("https://example.com/new", PostKind.NOTE, published = 2000)
        var library = Library().replacing(listOf(old), LibrarySource.feed).replacing(listOf(new), LibrarySource.feed)
        assertEquals(listOf("https://example.com/new", "https://example.com/old"), library.posts.map { it.url })
        library = library.replacing(listOf(new), LibrarySource.micropub)
        assertEquals(1, library.posts.size)
    }

    @Test fun editingSendsOnlyChangedProperties() {
        val source = obj("type" to strings("h-entry"), "properties" to obj(
            "content" to strings("First *draft*"), "category" to strings("one"), "p3k-content-type" to strings("text/markdown")))
        val draft = DraftSource.from(source, "https://example.com/1")
        assertEquals(PostKind.NOTE, draft.kind)
        assertFails<QuillException> { Payload.update(draft) }
        val body = Payload.update(draft.copy(content = "Second", tags = ""))
        assertEquals(strings("Second"), body["replace"].obj!!["content"])
        assertEquals(strings("text/markdown"), body["replace"].obj!!["p3k-content-type"])
        assertEquals(strings("category"), body["delete"])
        assertNull(body["replace"].obj!!["name"])
    }

    @Test fun richHtmlStaysHtmlWhenEditing() {
        val html = kotlinx.serialization.json.JsonArray(listOf(obj("html" to kotlinx.serialization.json.JsonPrimitive("<blockquote>Quote</blockquote>"))))
        assertTrue(DraftSource.from(obj("properties" to obj("content" to html)), "https://example.com/1").isHTML)
        val plainHtml = kotlinx.serialization.json.JsonArray(listOf(obj("html" to kotlinx.serialization.json.JsonPrimitive("<p>Just words</p>"))))
        val plain = DraftSource.from(obj("properties" to obj("content" to plainHtml)), "https://example.com/2")
        assertFalse(plain.isHTML)
        assertEquals("Just words", plain.content)
    }

    @Test fun structuredPostsAreNotEditedHere() {
        assertFails<QuillException> { DraftSource.from(obj("type" to strings("h-event"), "properties" to obj()), "https://example.com/e") }
    }

    @Test fun markdownNoteIsMarkedForTheServer() {
        val p = Payload.create(Draft(kind = PostKind.NOTE, content = "Hello *there*", fields = mapOf("p3k-content-type" to "text/markdown")))["properties"].obj!!
        assertEquals(strings("Hello *there*"), p["content"])
        assertEquals(strings("text/markdown"), p["p3k-content-type"])
    }

    @Test fun markdownArticleAppendsImagesAsMarkdown() {
        val photo = Attachment(data = ByteArray(0), filename = "a.jpg", mimeType = "image/jpeg", alt = "A cat", remoteURL = "https://example.com/a.jpg")
        val p = Payload.create(Draft(kind = PostKind.ARTICLE, title = "T", content = "# Heading", fields = mapOf("p3k-content-type" to "text/markdown"), attachments = listOf(photo)))["properties"].obj!!
        assertEquals(strings("# Heading\n\n![A cat](https://example.com/a.jpg)"), p["content"])
    }

    @Test fun preferencesFormatsAndOverrides() {
        val prefs = QuillJson.decodeFromString(Preferences.serializer(), """{"weightUnit":"kg"}""")
        assertEquals("kg", prefs.weightUnit)
        assertEquals(ContentFormat.PLAIN, prefs.format)
        assertEquals(PostKind.entries.size, prefs.visibleKinds.size)
        val custom = Preferences(format = ContentFormat.MARKDOWN, formatOverrides = mapOf(PostKind.ARTICLE to ContentFormat.HTML))
        val again = QuillJson.decodeFromString(Preferences.serializer(), QuillJson.encodeToString(Preferences.serializer(), custom))
        assertEquals(custom, again)
        assertEquals(ContentFormat.HTML, again.formatFor(PostKind.ARTICLE))
        assertEquals(ContentFormat.PLAIN, again.formatFor(PostKind.REVIEW))
        assertNull(again.formatFor(PostKind.LIKE))
    }

    @Test fun plainDefaultWritesArticlesInMarkdown() {
        var draft = Draft(kind = PostKind.NOTE).prepared(PostKind.ARTICLE)
        assertEquals(ContentFormat.MARKDOWN, draft.format)
        draft = draft.prepared(PostKind.NOTE)
        assertEquals(ContentFormat.PLAIN, draft.format)
    }

    @Test fun recordingsGoInTheAudioProperty() {
        val audio = Attachment(data = ByteArray(0), filename = "v.m4a", mimeType = "audio/mp4", remoteURL = "https://example.com/v.m4a")
        val photo = Attachment(data = ByteArray(0), filename = "a.jpg", mimeType = "image/jpeg", remoteURL = "https://example.com/a.jpg")
        val p = Payload.create(Draft(kind = PostKind.NOTE, content = "Said aloud", attachments = listOf(audio, photo)))["properties"].obj!!
        assertEquals(strings("https://example.com/v.m4a"), p["audio"])
        assertEquals(strings("https://example.com/a.jpg"), p["photo"])
        assertFails<QuillException> { Payload.validate(Draft(kind = PostKind.PHOTO, attachments = listOf(audio.copy(remoteURL = null)))) }
    }

    @Test fun htmlNoteSendsHtmlContent() {
        val p = Payload.create(Draft(kind = PostKind.NOTE, content = "<p>Hi</p>").withFormat(ContentFormat.HTML))["properties"].obj!!
        assertEquals("[{\"html\":\"<p>Hi</p>\"}]", p["content"].toString())
        assertEquals("Happy bday to @shannon today", Markdown.text("Happy bday to [@shannon](https://bsky.app/x) **today**"))
    }

    @Test fun openGraphGivesAuthorAndText() {
        val html = """<head><title>@vruba.bsky.social on Bluesky</title><meta property="og:title" content="Charlie Loyd (@vruba.bsky.social)"><meta property="og:description" content="(We&#39;ve got to solve this &amp; that)"></head>"""
        val summary = PageSummary.parse(html)
        assertEquals("Charlie Loyd (@vruba.bsky.social)", summary.author)
        assertEquals("(We've got to solve this & that)", summary.text)
        var post = Post("https://example.com/like", PostKind.LIKE, target = "https://bsky.app/profile/x/post/1")
        assertTrue(post.needsCite)
        post = post.copy(citeAuthor = summary.author, citeText = summary.text)
        assertEquals("(We've got to solve this & that)", post.displayTitle)
        assertEquals("Charlie Loyd", post.citeName)
        assertTrue(post.matches("solve loyd"))
    }

    @Test fun syncKeepsFetchedCites() {
        val post = Post("https://example.com/l", PostKind.LIKE, target = "https://b.example/1")
        var library = Library().replacing(listOf(post), LibrarySource.micropub)
        library = library.copy(posts = listOf(library.posts[0].copy(citeAuthor = "Ada", citeText = "Hi")))
        library = library.replacing(listOf(post), LibrarySource.micropub)
        assertEquals("Hi", library.posts[0].citeText)
    }

    @Test fun linkContextReadsOpenGraph() {
        val context = LinkContext.parse("""<title>Fallback</title><meta property="og:title" content="A &amp; B"><meta name="description" content="About"><meta property="og:image" content="/i.png"><meta name="keywords" content="one, two">""", "https://example.com/post")
        assertEquals("A & B", context.title)
        assertEquals("About", context.description)
        assertEquals("https://example.com/i.png", context.image)
        assertEquals(listOf("one", "two"), context.tags)
    }
}
