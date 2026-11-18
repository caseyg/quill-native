package com.quillnative.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.net.URI
import java.time.Instant
import java.util.Base64
import java.util.UUID

class QuillException(message: String, val status: Int? = null) : Exception(message)

@Serializable
enum class PostKind {
    @SerialName("note") NOTE,
    @SerialName("photo") PHOTO,
    @SerialName("reply") REPLY,
    @SerialName("article") ARTICLE,
    @SerialName("bookmark") BOOKMARK,
    @SerialName("like") LIKE,
    @SerialName("repost") REPOST,
    @SerialName("event") EVENT,
    @SerialName("review") REVIEW,
    @SerialName("itinerary") ITINERARY,
    @SerialName("code") CODE,
    @SerialName("weight") WEIGHT,
    @SerialName("exercise") EXERCISE;

    val raw: String get() = name.lowercase()
    val title: String get() = raw.replaceFirstChar { it.uppercase() }

    /** Kinds the composer can edit in place. Structured posts are edited on the site. */
    val isEditable: Boolean get() = this in setOf(NOTE, PHOTO, REPLY, ARTICLE, BOOKMARK, LIKE, REPOST, CODE)
    val hasTarget: Boolean get() = this in setOf(REPLY, BOOKMARK, LIKE, REPOST)
    val hasText: Boolean get() = this in setOf(NOTE, PHOTO, REPLY, BOOKMARK)
    val takesPhotos: Boolean get() = this in setOf(NOTE, PHOTO, REPLY, ARTICLE)
    val takesVoice: Boolean get() = this in setOf(NOTE, PHOTO, REPLY, BOOKMARK, ARTICLE)
    val takesLocation: Boolean get() = this !in setOf(LIKE, REPOST, WEIGHT, EXERCISE, ITINERARY)
    /** Kinds edited as a form rather than as prose. */
    val isStructured: Boolean get() = this in setOf(EVENT, REVIEW, ITINERARY, WEIGHT, EXERCISE)
    val prompt: String get() = when (this) {
        PHOTO -> "Caption"
        REPLY -> "Reply"
        BOOKMARK -> "Comment"
        else -> "Note"
    }

    val targetProperty: String? get() = when (this) {
        REPLY -> "in-reply-to"
        BOOKMARK -> "bookmark-of"
        LIKE -> "like-of"
        REPOST -> "repost-of"
        else -> null
    }
    internal val hasEditableText: Boolean get() = this == REPLY || this == BOOKMARK

    companion object {
        fun fromRaw(value: String?): PostKind? = entries.firstOrNull { it.raw == value }
    }
}

/** Bytes kept as Base64 in saved JSON, as Foundation's Codable does for Data. */
object Base64Serializer : KSerializer<ByteArray> {
    override val descriptor = PrimitiveSerialDescriptor("Base64", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: ByteArray) = encoder.encodeString(Base64.getEncoder().encodeToString(value))
    override fun deserialize(decoder: Decoder): ByteArray = Base64.getDecoder().decode(decoder.decodeString())
}

@Serializable
data class Attachment(
    val id: String = UUID.randomUUID().toString().uppercase(),
    @Serializable(with = Base64Serializer::class) val data: ByteArray,
    val filename: String,
    val mimeType: String,
    val alt: String = "",
    val remoteURL: String? = null,
) {
    /** A voice recording, sent as `audio` rather than `photo`. */
    val isAudio: Boolean get() = mimeType.startsWith("audio/")

    override fun equals(other: Any?): Boolean = other is Attachment && id == other.id && alt == other.alt &&
        remoteURL == other.remoteURL && filename == other.filename && mimeType == other.mimeType && data.contentEquals(other.data)
    override fun hashCode(): Int = id.hashCode() * 31 + alt.hashCode()
}

@Serializable
data class Leg(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val transitType: String = "air",
    val operatorName: String = "",
    val number: String = "",
    val origin: String = "",
    val destination: String = "",
    val departure: String = "",
    val arrival: String = "",
)

@Serializable
data class Draft(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val kind: PostKind,
    val title: String = "",
    val content: String = "",
    val isHTML: Boolean = false,
    val target: String = "",
    val tags: String = "",
    val slug: String = "",
    val visibility: String = "",
    val channel: String = "",
    val syndication: List<String> = emptyList(),
    val location: String = "",
    val published: String = "",
    val remoteDraft: Boolean = false,
    val fields: Map<String, String> = emptyMap(),
    val legs: List<Leg> = emptyList(),
    val attachments: List<Attachment> = emptyList(),
    val editURL: String? = null,
    /** The edited properties as they were fetched, so an update sends only what changed. */
    val original: Map<String, String>? = null,
    val accountURL: String? = null,
    /** Milliseconds since 1970. */
    val modified: Long = System.currentTimeMillis(),
) {
    fun field(name: String): String = fields[name].orEmpty()
    fun withField(name: String, value: String?): Draft = copy(fields = if (value == null) fields - name else fields + (name to value))

    val tagList: List<String> get() = tags.split(',').map { it.trim() }.filter { it.isNotEmpty() }

    /** The title, else the body, else a photo description, else the link it responds to. */
    val displayTitle: String get() {
        val body = if (isHTML) Html.text(content) else content
        for (value in listOf(title, body, attachments.firstOrNull { it.alt.isNotEmpty() }?.alt.orEmpty(), target)) {
            val line = value.trim()
            if (line.isNotEmpty()) return line.take(80)
        }
        return "Untitled ${kind.title}"
    }

    /** True when nothing worth keeping has been entered, so closing the composer leaves no draft behind. */
    val isBlank: Boolean get() {
        val defaults = setOf("rating", "start", "p3k-content-type")
        return editURL == null && attachments.isEmpty() && listOf(title, content, target, tags, location).all { it.isBlank() } &&
            fields.all { it.key in defaults || it.value.isBlank() } &&
            legs.all { listOf(it.origin, it.destination, it.operatorName, it.number).all(String::isBlank) }
    }

    /** The format the body is written in, kept as `isHTML` and Quill's `p3k-content-type` marker. */
    val format: ContentFormat get() = when {
        isHTML -> ContentFormat.HTML
        fields["p3k-content-type"] == "text/markdown" -> ContentFormat.MARKDOWN
        else -> ContentFormat.PLAIN
    }

    fun withFormat(value: ContentFormat): Draft {
        var next = copy(isHTML = value == ContentFormat.HTML)
        if (value == ContentFormat.MARKDOWN) next = next.withField("p3k-content-type", "text/markdown")
        else if (fields["p3k-content-type"] == "text/markdown") next = next.withField("p3k-content-type", null)
        return next
    }

    /** Fills in what a post type needs before it can be edited, in the format the preferences give it. */
    fun prepared(kind: PostKind, preferences: Preferences = Preferences()): Draft {
        var d = copy(kind = kind)
        if (kind == PostKind.ITINERARY && d.legs.isEmpty()) d = d.copy(legs = listOf(Leg()))
        if (kind == PostKind.REVIEW && d.field("rating").isEmpty()) d = d.withField("rating", "5")
        val format = preferences.formatFor(kind)
        // A format picked for this post is kept when the type can use it.
        d = if (format != null) d.withFormat(if (d.format in ContentFormat.supported(kind) && !d.isBlank) d.format else format)
        else d.withFormat(ContentFormat.PLAIN)
        return d
    }

    fun withPublicationDate(enabled: Boolean, now: Instant = Instant.now()): Draft = when {
        !enabled -> copy(published = "")
        published.isEmpty() -> copy(published = Iso8601.format(now))
        else -> this
    }

    /** The values an update compares against the post as fetched. */
    val editableValues: Map<String, String> get() {
        val values = mutableMapOf("name" to title, "category" to tags)
        if (kind.targetProperty == null || kind.hasEditableText) values["content"] = content
        kind.targetProperty?.let { values[it] = target }
        return values
    }

    companion object {
        fun create(kind: PostKind, preferences: Preferences = Preferences(), accountURL: String? = null): Draft =
            Draft(kind = kind, accountURL = accountURL).prepared(kind, preferences)
    }
}

/** How a post's text is written and marked when it is sent. */
@Serializable
enum class ContentFormat(val title: String) {
    @SerialName("plain") PLAIN("Plain Text"),
    @SerialName("markdown") MARKDOWN("Markdown"),
    @SerialName("html") HTML("HTML");

    /** The nearest format a post type can use, or null when it has no free text. */
    fun fitted(kind: PostKind): ContentFormat? {
        val options = supported(kind)
        if (this in options) return this
        // Articles have a formatting editor, so plain text becomes Markdown there.
        if (this == PLAIN && MARKDOWN in options) return MARKDOWN
        return if (PLAIN in options) PLAIN else options.firstOrNull()
    }

    companion object {
        /** The formats a post type's body can be written in. Types without free text have none. */
        fun supported(kind: PostKind): List<ContentFormat> = when (kind) {
            PostKind.NOTE, PostKind.PHOTO, PostKind.REPLY, PostKind.BOOKMARK -> listOf(PLAIN, MARKDOWN, HTML)
            PostKind.ARTICLE -> listOf(MARKDOWN, HTML)
            PostKind.EVENT -> listOf(PLAIN, MARKDOWN)
            PostKind.REVIEW -> listOf(PLAIN, HTML)
            else -> emptyList()
        }
    }
}

@Serializable
data class Preferences(
    val slugField: String = "mp-slug",
    val syndicationField: String = "mp-syndicate-to",
    /** Send HTML as `{"html": …}`, as Micropub defines, instead of a bare string. */
    val htmlContent: Boolean = true,
    val weightUnit: String = "lb",
    /** The format new posts are written in. */
    val format: ContentFormat = ContentFormat.PLAIN,
    /** Post types written in a different format from `format`. */
    val formatOverrides: Map<PostKind, ContentFormat> = emptyMap(),
    /** Post types left out of the new-post menu and the post list. */
    val hiddenKinds: List<PostKind> = emptyList(),
    /** Send posts form-encoded instead of as JSON, for servers that only read forms. */
    val formEncoded: Boolean = false,
) {
    val visibleKinds: List<PostKind> get() = PostKind.entries.filter { it !in hiddenKinds }

    /** The format a new post of this type starts in, or null when the type has no free text. */
    fun formatFor(kind: PostKind): ContentFormat? = (formatOverrides[kind] ?: format).fitted(kind)

    companion object {
        /** Kinds whose body can be written as Markdown. */
        val markdownKinds = listOf(PostKind.NOTE, PostKind.PHOTO, PostKind.REPLY, PostKind.ARTICLE, PostKind.BOOKMARK)
    }
}

@Serializable
data class Account(
    val me: String,
    val micropub: String,
    val tokenEndpoint: String? = null,
    val scope: String = "create update media",
) {
    fun permits(action: String): Boolean = scope.split(' ').contains(action)
    val host: String get() = runCatching { URI(me).host }.getOrNull() ?: me
}

@Serializable
data class Receipt(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val title: String,
    val kind: PostKind,
    val url: String,
    val date: Long = System.currentTimeMillis(),
    val accountURL: String? = null,
    val status: String,
) {
    companion object {
        fun of(draft: Draft, url: String, now: Instant = Instant.now()) = Receipt(
            title = draft.displayTitle, kind = draft.kind, url = url, date = now.toEpochMilli(), accountURL = draft.accountURL,
            status = when {
                draft.editURL != null -> "Updated"
                draft.remoteDraft -> "Draft"
                Iso8601.parse(draft.published)?.isAfter(now) == true -> "Scheduled"
                else -> "Published"
            },
        )
    }
}

object WebUrl {
    /** An absolute http or https address without credentials. */
    fun parse(value: String): String {
        val trimmed = value.trim()
        val uri = runCatching { URI(trimmed) }.getOrNull()
        if (uri == null || uri.scheme?.lowercase() !in setOf("http", "https") || uri.host.isNullOrEmpty() || uri.userInfo != null) {
            throw QuillException("Enter a valid http or https URL.")
        }
        return trimmed
    }

    fun parseOrNull(value: String?): String? = value?.let { runCatching { parse(it) }.getOrNull() }

    /** A website address, with https:// added to a bare domain and a root path added when there is none. */
    fun site(value: String): String {
        val input = value.trim()
        if (input.isEmpty() || input.any(Char::isWhitespace)) throw QuillException("Enter a valid http or https URL.")
        val url = parse(if ("://" in input) input else "https://$input")
        val uri = URI(url)
        if (!uri.rawPath.isNullOrEmpty()) return url
        return uri.scheme + "://" + uri.rawAuthority + "/" + (uri.rawQuery?.let { "?$it" } ?: "") + (uri.rawFragment?.let { "#$it" } ?: "")
    }

    /** Resolves a possibly relative reference against a base address. */
    fun resolve(base: String, reference: String): String? = runCatching { URI(base).resolve(URI(reference.trim())).toString() }.getOrNull()

    fun host(value: String): String? = runCatching { URI(value).host }.getOrNull()
}
