package com.quillnative.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.File
import java.io.StringReader
import java.text.Normalizer
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import javax.xml.parsers.SAXParserFactory

/** A published post as the app keeps it on device for listing and search. */
@Serializable
data class Post(
    val url: String,
    val kind: PostKind,
    val name: String = "",
    /** Plain text of the content, for display and search. */
    val text: String = "",
    val target: String = "",
    val categories: List<String> = emptyList(),
    val photo: String? = null,
    val photoAlt: String = "",
    /** Milliseconds since 1970. */
    val published: Long? = null,
    val isDraft: Boolean = false,
    /** Who wrote the post this one responds to, such as "Erin Kissane (@kissane.bsky.social)". */
    val citeAuthor: String? = null,
    /** The text of the post this one responds to. */
    val citeText: String? = null,
) {
    val id: String get() = url

    /** True until the responded-to page has been read. A page with nothing to show leaves empty strings. */
    val needsCite: Boolean get() = target.isNotEmpty() && citeAuthor == null && citeText == null

    /** The name, else the body, else the photo description, else the link it responds to. */
    val displayTitle: String get() {
        for (value in listOf(name, text, photoAlt, citeText.orEmpty(), citeAuthor.orEmpty(), target)) {
            val line = value.trim()
            if (line.isNotEmpty()) return line.take(200)
        }
        val path = runCatching { java.net.URI(url).path }.getOrNull().orEmpty()
        return if (path == "/" || path.isEmpty()) url else path
    }

    /** The author's display name, without the handle Bluesky and Mastodon add in parentheses. */
    val citeName: String? get() {
        val author = citeAuthor?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return author.replace(Regex("\\s*\\(@[^)]*\\)$"), "")
    }

    fun matches(query: String): Boolean {
        val terms = query.split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (terms.isEmpty()) return true
        val haystack = fold((listOf(name, text, photoAlt, target, citeAuthor.orEmpty(), citeText.orEmpty(), url) + categories).joinToString("\n"))
        return terms.all { fold(it) in haystack }
    }

    companion object {
        /** Case- and accent-insensitive form for search. */
        fun fold(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT)

        private val targetKeys = listOf("in-reply-to", "bookmark-of", "like-of", "repost-of")

        /** Reads a microformats2 object, such as an item from `q=source` or a `q=source&url=` response. */
        fun fromMf2(value: JsonElement, fallback: String? = null): Post? {
            val p = value.obj?.get("properties").obj ?: return null
            val type = value.obj?.get("type").arr?.firstOrNull().str ?: "h-entry"
            val url = WebUrl.parseOrNull(p["url"].arr?.firstOrNull().str) ?: fallback ?: return null
            val kind = PostKinds.discover(type, p)
            val content = Mf2.content(p["content"])
            var name = Mf2.text(p["name"])
            val text = if (Mf2.text(p["p3k-content-type"]) == "text/markdown") Markdown.text(content.text) else content.text
            if (name.trim() == text.take(name.length).trim() && kind != PostKind.ARTICLE) name = ""
            val target = targetKeys.firstNotNullOfOrNull { Mf2.url(p[it]) }.orEmpty()
            var citeAuthor: String? = null
            var citeText: String? = null
            // Servers may describe the target as an h-cite with its author and text.
            targetKeys.firstNotNullOfOrNull { p[it].arr?.firstOrNull().obj?.get("properties").obj }?.let { cite ->
                val author = Mf2.text(cite["author"]); val quoted = Mf2.content(cite["content"]).text; val title = Mf2.text(cite["name"])
                if (author.isNotEmpty()) citeAuthor = author
                if (quoted.isNotEmpty() || title.isNotEmpty()) citeText = quoted.ifEmpty { title }
            }
            var photo: String? = null
            var photoAlt = ""
            val first = p["photo"].arr?.firstOrNull()
            if (first != null) {
                val raw = first.str ?: first.obj?.get("value").str ?: first.obj?.get("url").str
                // Servers may store photos as paths relative to the post.
                photo = raw?.let { WebUrl.resolve(url, it) }?.let(WebUrl::parseOrNull)
                photoAlt = first.obj?.get("alt").str.orEmpty()
            } else content.image?.let { photo = it.url; photoAlt = it.alt }
            val published = Mf2.text(p["published"]).takeIf { it.isNotEmpty() }?.let { Mf2.date(it)?.toEpochMilli() }
            val isDraft = Mf2.text(p["post-status"]) == "draft" || p["draft"].arr?.firstOrNull().bool == true
            return Post(url, kind, name, text, target, p["category"].arr.orEmpty().mapNotNull { it.str }, photo, photoAlt, published, isDraft, citeAuthor, citeText)
        }

        /** What a just-sent draft looks like in the list until the next sync. */
        fun fromDraft(draft: Draft, url: String, now: Long = System.currentTimeMillis()): Post {
            val text = when {
                draft.isHTML -> Html.text(draft.content)
                draft.fields["p3k-content-type"] == "text/markdown" -> Markdown.text(draft.content)
                else -> draft.content
            }
            val photo = draft.attachments.firstOrNull { !it.isAudio }
            return Post(
                url = url, kind = draft.kind, name = draft.title, text = text, target = draft.target, categories = draft.tagList,
                photo = photo?.remoteURL, photoAlt = photo?.alt.orEmpty(),
                published = Iso8601.parse(draft.published)?.toEpochMilli() ?: now, isDraft = draft.remoteDraft,
            )
        }
    }
}

object PostKinds {
    /** Post type discovery, close to the IndieWeb algorithm, extended for Quill's types. */
    fun discover(type: String, p: JsonObject): PostKind {
        if (type == "h-event") return PostKind.EVENT
        if (type == "h-review") return PostKind.REVIEW
        if (p["itinerary"] != null) return PostKind.ITINERARY
        if (p["workout"] != null) return PostKind.EXERCISE
        if (p["weight"] != null) return PostKind.WEIGHT
        if (p["like-of"] != null) return PostKind.LIKE
        if (p["repost-of"] != null) return PostKind.REPOST
        if (p["bookmark-of"] != null) return PostKind.BOOKMARK
        if (p["in-reply-to"] != null) return PostKind.REPLY
        if (Mf2.text(p["p3k-content-type"]).startsWith("code/")) return PostKind.CODE
        if (p["photo"] != null) return PostKind.PHOTO
        val name = Mf2.text(p["name"]).trim()
        val content = Mf2.content(p["content"]).text.trim()
        if (name.isNotEmpty() && !content.startsWith(name)) return PostKind.ARTICLE
        return PostKind.NOTE
    }
}

object DraftSource {
    /** A draft for editing a post, from its `q=source` properties. */
    fun from(value: JsonElement, url: String): Draft {
        val p = value.obj?.get("properties").obj ?: throw QuillException("The source response contains no properties.")
        val type = value.obj?.get("type").arr?.firstOrNull().str ?: "h-entry"
        val kind = PostKinds.discover(type, p)
        if (!kind.isEditable) throw QuillException("${kind.title} posts can’t be edited here yet.")
        var title = Mf2.text(p["name"])
        val content = Mf2.content(p["content"])
        var isHTML = false
        val body = if (content.html != null && (kind == PostKind.ARTICLE || !Html.isPlain(content.html))) { isHTML = true; content.html }
        else content.html?.let(Html::text) ?: content.text
        if (kind != PostKind.ARTICLE && kind != PostKind.CODE && title.isNotEmpty() && body.startsWith(title)) title = ""
        val fields = mutableMapOf<String, String>()
        val format = Mf2.text(p["p3k-content-type"])
        if (kind == PostKind.CODE) fields["language"] = format.replace("code/", "")
        else if (format.isNotEmpty()) fields["p3k-content-type"] = format
        val draft = Draft(
            kind = kind, editURL = url, title = title, content = body, isHTML = isHTML,
            target = kind.targetProperty?.let { Mf2.url(p[it]) }.orEmpty(),
            tags = p["category"].arr.orEmpty().mapNotNull { it.str }.joinToString(", "),
            fields = fields, published = Mf2.text(p["published"]),
        )
        return draft.copy(original = draft.editableValues)
    }
}

data class PostPage(val posts: List<Post>, val after: String?)

@Serializable
enum class LibrarySource { micropub, feed }

object Feed {
    /** Feed links in a page, best first: JSON Feed, then Atom, then RSS. */
    fun links(html: String, baseUrl: String): List<String> {
        val ranked = mapOf("application/feed+json" to 0, "application/json" to 1, "application/atom+xml" to 2, "application/rss+xml" to 3)
        val found = mutableListOf<Pair<Int, String>>()
        for (match in Regex("<link\\b[^>]*>", RegexOption.IGNORE_CASE).findAll(html)) {
            val tag = match.value
            fun attribute(name: String): String? {
                val m = Regex("\\b" + name + "\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", RegexOption.IGNORE_CASE).find(tag) ?: return null
                return m.value.split("=", limit = 2)[1].trim('"', '\'', ' ')
            }
            if (attribute("rel")?.lowercase()?.split(' ')?.contains("alternate") != true) continue
            val rank = ranked[attribute("type")?.lowercase().orEmpty()] ?: continue
            val href = attribute("href") ?: continue
            val url = WebUrl.resolve(baseUrl, href.replace("&amp;", "&")) ?: continue
            if (found.none { it.second == url }) found += rank to url
        }
        return found.sortedBy { it.first }.map { it.second }
    }

    data class Parsed(val posts: List<Post>, val next: String?)

    /** Posts in a JSON Feed, Atom or RSS document, and the next page for JSON Feed. */
    fun parse(text: String): Parsed {
        val json = parseJson(text).obj
        if (json != null) {
            val posts = json["items"].arr.orEmpty().mapNotNull { item ->
                val o = item.obj ?: return@mapNotNull null
                val url = WebUrl.parseOrNull(o["url"].str ?: o["id"].str) ?: return@mapNotNull null
                post(url, o["title"].str, o["content_html"].str, o["content_text"].str ?: o["summary"].str, o["image"].str,
                    o["date_published"].str, o["tags"].arr.orEmpty().mapNotNull { it.str })
            }
            return Parsed(posts, WebUrl.parseOrNull(json["next_url"].str))
        }
        val entries = runCatching { xmlEntries(text) }.getOrDefault(emptyList())
        return Parsed(entries.mapNotNull { e ->
            val url = WebUrl.parseOrNull(e["link"] ?: e["guid"]) ?: return@mapNotNull null
            post(url, e["title"], e["content"] ?: e["description"] ?: e["summary"], null, null,
                e["published"] ?: e["pubDate"] ?: e["updated"], listOfNotNull(e["category"]))
        }, null)
    }

    private fun post(url: String, title: String?, html: String?, text: String?, image: String?, date: String?, tags: List<String>): Post {
        val body = html?.let(Html::text) ?: text ?: ""
        val name = title.orEmpty().trim()
        val picture = html?.let(Html::firstImage)
        val kind = if (name.isNotEmpty() && !body.startsWith(name)) PostKind.ARTICLE else if (picture != null || image != null) PostKind.PHOTO else PostKind.NOTE
        return Post(
            url = url, kind = kind, name = if (kind == PostKind.ARTICLE) name else "", text = body,
            photo = WebUrl.parseOrNull(image) ?: picture?.url, photoAlt = picture?.alt.orEmpty(), categories = tags,
            published = date?.let { (Mf2.date(it) ?: rfc822(it))?.toEpochMilli() },
        )
    }

    private fun rfc822(value: String) = runCatching { ZonedDateTime.parse(value.trim(), DateTimeFormatter.RFC_1123_DATE_TIME).toInstant() }.getOrNull()

    /** `<item>` and `<entry>` fields from RSS and Atom. */
    private fun xmlEntries(text: String): List<Map<String, String>> {
        val entries = mutableListOf<Map<String, String>>()
        val factory = SAXParserFactory.newInstance()
        runCatching { factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
        factory.isNamespaceAware = false
        factory.newSAXParser().parse(InputSource(StringReader(text)), object : DefaultHandler() {
            var current: MutableMap<String, String>? = null
            val buffer = StringBuilder()
            override fun startElement(uri: String?, localName: String?, qName: String, attributes: Attributes) {
                val name = qName
                if (name == "item" || name == "entry") current = mutableMapOf()
                else if (current != null && name == "link" && attributes.getValue("href") != null && (attributes.getValue("rel") == null || attributes.getValue("rel") == "alternate")) current!!["link"] = attributes.getValue("href")
                else if (current != null && name == "category" && attributes.getValue("term") != null) current!!["category"] = attributes.getValue("term")
                buffer.setLength(0)
            }
            override fun characters(ch: CharArray, start: Int, length: Int) { buffer.append(ch, start, length) }
            override fun endElement(uri: String?, localName: String?, qName: String) {
                if (qName == "item" || qName == "entry") { current?.let { entries += it }; current = null; return }
                val value = buffer.toString().trim()
                val key = qName.replace("content:encoded", "content")
                current?.let { if (value.isNotEmpty() && it[key] == null) it[key] = value }
            }
        })
        return entries
    }
}

object PageSummary {
    data class Summary(val author: String, val text: String)

    /** The author and text a page shares in its Open Graph tags, as Bluesky and Mastodon posts do. */
    fun parse(html: String): Summary {
        fun meta(name: String): String? {
            for (match in Regex("<meta\\b[^>]*>", RegexOption.IGNORE_CASE).findAll(html)) {
                val tag = match.value
                fun attribute(key: String): String? {
                    val m = Regex("\\b" + key + "\\s*=\\s*(\"[^\"]*\"|'[^']*')", RegexOption.IGNORE_CASE).find(tag) ?: return null
                    return m.value.split("=", limit = 2)[1].trim().drop(1).dropLast(1)
                }
                if (listOf(attribute("property"), attribute("name")).any { it?.lowercase() == name }) attribute("content")?.let { return Html.text(it) }
            }
            return null
        }
        var title = meta("og:title").orEmpty()
        if (title.isEmpty()) Regex("<title[^>]*>[^<]*", RegexOption.IGNORE_CASE).find(html)?.let {
            title = Html.text(it.value.replace(Regex("<title[^>]*>", RegexOption.IGNORE_CASE), ""))
        }
        return Summary(title, meta("og:description") ?: meta("description") ?: "")
    }
}

@Serializable
data class Library(
    val posts: List<Post> = emptyList(),
    val source: LibrarySource? = null,
    val synced: Long? = null,
    /** False while a first download has not reached the oldest post. */
    val complete: Boolean? = null,
) {
    /** Whether a refresh only needs posts newer than the ones on device. */
    val isComplete: Boolean get() = complete ?: (synced != null)

    /**
     * Newest first. Posts without a date keep the server's order at the end.
     * `keeping` holds on to posts the fetch did not include, for a feed or a refresh that stopped at known posts.
     */
    fun replacing(with: List<Post>, source: LibrarySource, keeping: Boolean = false, complete: Boolean = true, now: Long = System.currentTimeMillis()): Library {
        val seen = mutableSetOf<String>()
        val known = posts.associateBy { it.id }
        val merged = with.filter { seen.add(it.id) }.map { post ->
            // Keep what was read from the responded-to page, which the server doesn't send.
            val old = known[post.id]
            if (post.needsCite && old != null && old.target == post.target) post.copy(citeAuthor = old.citeAuthor, citeText = old.citeText) else post
        }.toMutableList()
        // A feed shows only recent posts, so keep older ones already on device.
        if (source == LibrarySource.feed || keeping) merged += posts.filter { seen.add(it.id) }
        val sorted = merged.withIndex().sortedWith { a, b ->
            val x = a.value.published; val y = b.value.published
            when {
                x != null && y != null -> y.compareTo(x)
                x != null -> -1
                y != null -> 1
                else -> a.index.compareTo(b.index)
            }
        }.map { it.value }
        return Library(sorted, source, now, complete)
    }

    /** Replaces a post in place, or adds a new one at the top. */
    fun upserting(post: Post): Library {
        val index = posts.indexOfFirst { it.id == post.id }
        return copy(posts = if (index >= 0) posts.toMutableList().also { it[index] = post } else listOf(post) + posts)
    }

    fun search(query: String): List<Post> = posts.filter { it.matches(query) }
}

class LibraryStore(val file: File) {
    fun load(): Library = runCatching { QuillJson.decodeFromString(Library.serializer(), file.readText()) }.getOrDefault(Library())
    fun save(library: Library) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeText(QuillJson.encodeToString(Library.serializer(), library))
        if (!temp.renameTo(file)) { file.delete(); temp.renameTo(file) }
    }
    fun delete() { file.delete() }
}

object LibrarySync {
    data class Result(val posts: List<Post>, val source: LibrarySource, val finished: Boolean)

    /**
     * Every post from Micropub when the server lists them, otherwise recent posts from the site's feed.
     * `progress` receives each page as it arrives, so a list can fill in while the rest downloads.
     */
    suspend fun fetch(
        client: MicropubClient, me: String, maxPages: Int = 200, known: Set<String> = emptySet(),
        transport: Transport = Network.transport, progress: suspend (List<Post>) -> Unit = {},
    ): Result {
        // Pages run newest first, so a page with a post already on device means the rest are too.
        fun reachesKnown(page: List<Post>) = known.isNotEmpty() && page.any { it.id in known }
        val firstPage = client.posts()
        if (firstPage != null) {
            var page: PostPage = firstPage
            val posts = page.posts.toMutableList()
            progress(page.posts)
            val cursors = mutableSetOf<String>()
            var finished = true
            if (!reachesKnown(page.posts)) {
                finished = false
                for (i in 1 until maxPages) {
                    val after = page.after
                    if (after == null || !cursors.add(after) || page.posts.isEmpty()) { finished = true; break }
                    val next = client.posts(after = after)
                    if (next == null) { finished = true; break }
                    page = next; posts += next.posts
                    progress(next.posts)
                    if (reachesKnown(next.posts)) { finished = true; break }
                }
            }
            return Result(posts, LibrarySource.micropub, finished)
        }
        val home = transport.send(HttpRequest(me))
        Network.check(home)
        val feedUrl = Feed.links(home.text, home.url.ifEmpty { me }).firstOrNull() ?: throw QuillException("Your site doesn’t list its posts.")
        val posts = mutableListOf<Post>()
        var next: String? = feedUrl
        val visited = mutableSetOf<String>()
        while (next != null && visited.add(next) && visited.size <= maxPages) {
            val response = transport.send(HttpRequest(next)); Network.check(response)
            val parsed = Feed.parse(response.text)
            posts += parsed.posts; next = parsed.next
            progress(parsed.posts)
            if (reachesKnown(parsed.posts)) next = null
        }
        return Result(posts, LibrarySource.feed, next == null || next in visited)
    }
}

/** Separate atomic files avoid lost updates between the app and the share sheet. */
class DraftStore(val directory: File) {
    fun save(draft: Draft) {
        directory.mkdirs()
        val file = File(directory, draft.id + ".json")
        val temp = File(directory, draft.id + ".json.tmp")
        temp.writeText(QuillJson.encodeToString(Draft.serializer(), draft))
        if (!temp.renameTo(file)) { file.delete(); temp.renameTo(file) }
    }

    fun load(): List<Draft> = directory.listFiles { f -> f.name.endsWith(".json") }.orEmpty()
        .mapNotNull { runCatching { QuillJson.decodeFromString(Draft.serializer(), it.readText()) }.getOrNull() }
        .sortedByDescending { it.modified }

    fun delete(id: String) { File(directory, "$id.json").delete() }
}

internal fun JsonObject.toSortedMap(): java.util.SortedMap<String, JsonElement> = java.util.TreeMap(this)
