package com.quillnative.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.Base64

/** Micropub request bodies for a draft. Ported from QuillCore's Payload. */
object Payload {
    private fun require(value: String, message: String) { if (value.isBlank()) throw QuillException(message) }

    fun validate(d: Draft) {
        when (d.kind) {
            PostKind.NOTE -> require(d.content, "Write something before publishing.")
            PostKind.PHOTO -> if (d.attachments.none { !it.isAudio } && d.field("photo-url").isEmpty()) throw QuillException("Add a photo first.")
            PostKind.REPLY, PostKind.BOOKMARK, PostKind.LIKE, PostKind.REPOST -> WebUrl.parse(d.target)
            PostKind.ARTICLE -> if (d.attachments.isEmpty() && d.field("photo-url").isEmpty()) require(d.content, "Add content before publishing.")
            PostKind.CODE -> require(d.content, "Add content before publishing.")
            PostKind.EVENT -> {
                require(d.title, "Give the event a name.")
                require(d.field("start"), "Choose an event start.")
                val s = Iso8601.parse(d.fields["start"])
                val e = Iso8601.parse(d.fields["end"])
                if (s != null && e != null && e.isBefore(s)) throw QuillException("The event end must follow its start.")
            }
            PostKind.REVIEW -> {
                require(d.field("item-name"), "Name the item you’re reviewing.")
                WebUrl.parse(d.field("item-url"))
                val rating = d.field("rating").toDoubleOrNull()
                if (rating == null || rating !in 1.0..5.0) throw QuillException("Choose a rating from 1 to 5.")
            }
            PostKind.WEIGHT -> {
                val value = d.field("weight").toDoubleOrNull()
                if (value == null || !value.isFinite() || value <= 0) throw QuillException("Enter a positive weight.")
            }
            PostKind.EXERCISE -> {
                require(d.field("activity"), "Choose an activity.")
                val minutes = d.field("minutes").toDoubleOrNull()
                if (minutes == null || !minutes.isFinite() || minutes <= 0) throw QuillException("Enter a positive duration in minutes.")
                val hr = d.field("heartrate")
                if (hr.isNotEmpty() && hr.toDoubleOrNull()?.let { it.isFinite() && it > 0 } != true) throw QuillException("Enter a positive heart rate.")
            }
            PostKind.ITINERARY -> {
                if (d.legs.isEmpty()) throw QuillException("Add at least one travel leg.")
                for (leg in d.legs) {
                    require(leg.origin, "Enter each leg’s origin.")
                    require(leg.destination, "Enter each leg’s destination.")
                    val depart = Iso8601.parse(leg.departure)
                    val arrive = Iso8601.parse(leg.arrival)
                    if (depart == null || arrive == null || arrive.isBefore(depart)) {
                        throw QuillException("Enter valid departure and arrival times with time zone offsets, in travel order.")
                    }
                }
            }
        }
        if (d.published.isNotEmpty() && Iso8601.parse(d.published) == null) throw QuillException("Enter a publication date with a time zone.")
    }

    /** The h-type a draft is posted as, without the "h-" prefix. */
    fun hType(kind: PostKind): String = when (kind) {
        PostKind.EVENT -> "event"
        PostKind.REVIEW -> "review"
        else -> "entry"
    }

    fun create(d: Draft, preferences: Preferences = Preferences()): JsonObject {
        validate(d)
        val p = linkedMapOf<String, JsonElement>()
        fun put(key: String, value: String) { if (value.isNotEmpty()) p[key] = jsonStrings(listOf(value)) }
        put("name", d.title)
        val markdown = !d.isHTML && d.fields["p3k-content-type"] == "text/markdown" && d.kind in Preferences.markdownKinds
        val content = if (d.kind == PostKind.ARTICLE) (if (markdown) articleMarkdown(d) else articleHTML(d)) else d.content
        if (content.isNotEmpty()) {
            p["content"] = JsonArray(listOf(if (d.isHTML && preferences.htmlContent) JsonObject(mapOf("html" to JsonPrimitive(content))) else JsonPrimitive(content)))
        }
        // Micropub defines plain text and HTML; Quill's p3k-content-type marks the text as Markdown.
        if (markdown && content.isNotEmpty()) put("p3k-content-type", "text/markdown")
        if (d.tagList.isNotEmpty()) p["category"] = jsonStrings(d.tagList)
        put(preferences.slugField, d.slug); put("visibility", d.visibility); put("p3k-channel", d.channel); put("location", d.location); put("published", d.published)
        if (d.remoteDraft) put("post-status", "draft")
        if ((d.visibility.isEmpty() || d.visibility == "public") && d.syndication.isNotEmpty()) p[preferences.syndicationField] = jsonStrings(d.syndication)
        when (d.kind) {
            PostKind.REPLY -> { put("in-reply-to", d.target); put("rsvp", d.field("rsvp")) }
            PostKind.BOOKMARK -> { put("bookmark-of", d.target); put("summary", d.field("summary")) }
            PostKind.LIKE -> put("like-of", d.target)
            PostKind.REPOST -> put("repost-of", d.target)
            PostKind.EVENT -> {
                for (key in listOf("start", "end", "p3k-content-type", "slides", "slides-embed", "video-link", "video-embed")) put(key, d.field(key))
                val conference = d.field("conference-name")
                if (conference.isNotEmpty()) {
                    p["conference"] = JsonArray(listOf(nested("h-event", mapOf("name" to jsonStrings(listOf(conference)), "url" to jsonStrings(listOf(d.field("conference-url")))))))
                }
                if (d.field("place-name").isNotEmpty()) {
                    val place = linkedMapOf<String, JsonElement>("name" to jsonStrings(listOf(d.field("place-name"))))
                    for (key in listOf("street-address", "locality", "region", "country-name", "latitude", "longitude", "url")) {
                        val v = d.field("place-$key"); if (v.isNotEmpty()) place[key] = jsonStrings(listOf(v))
                    }
                    p["location"] = JsonArray(listOf(nested("h-card", place)))
                }
            }
            PostKind.REVIEW -> {
                p["item"] = JsonArray(listOf(nested("h-product", mapOf("name" to jsonStrings(listOf(d.field("item-name"))), "url" to jsonStrings(listOf(d.field("item-url")))))))
                p["rating"] = JsonArray(listOf(jsonNumber(d.field("rating").toDoubleOrNull() ?: 1.0)))
                put("summary", d.field("summary"))
            }
            PostKind.ITINERARY -> p["itinerary"] = JsonArray(d.legs.map { leg ->
                nested("h-leg", linkedMapOf(
                    "transit-type" to jsonStrings(listOf(leg.transitType)), "operator" to jsonStrings(listOf(leg.operatorName)),
                    "number" to jsonStrings(listOf(leg.number)), "origin" to jsonStrings(listOf(leg.origin)),
                    "destination" to jsonStrings(listOf(leg.destination)), "departure" to jsonStrings(listOf(leg.departure)),
                    "arrival" to jsonStrings(listOf(leg.arrival)),
                ))
            })
            PostKind.CODE -> put("p3k-content-type", "code/" + (d.fields["language"] ?: "text"))
            PostKind.WEIGHT -> p["weight"] = JsonArray(listOf(nested("h-measure", mapOf(
                "num" to JsonArray(listOf(jsonNumber(d.field("weight").toDoubleOrNull() ?: 0.0))), "unit" to jsonStrings(listOf(preferences.weightUnit))))))
            PostKind.EXERCISE -> {
                val workout = linkedMapOf<String, JsonElement>(
                    "activity" to jsonStrings(listOf(d.field("activity"))),
                    "duration" to JsonArray(listOf(nested("h-measure", mapOf(
                        "num" to JsonArray(listOf(jsonNumber((d.field("minutes").toDoubleOrNull() ?: 0.0) * 60))), "unit" to jsonStrings(listOf("second")))))),
                )
                d.field("heartrate").toDoubleOrNull()?.let {
                    workout["heartrate"] = JsonArray(listOf(nested("h-measure", mapOf("num" to JsonArray(listOf(jsonNumber(it))), "unit" to jsonStrings(listOf("bpm"))))))
                }
                p["workout"] = JsonArray(listOf(nested("h-workout", workout)))
            }
            else -> {}
        }
        val audio = d.attachments.filter { it.isAudio }.mapNotNull { it.remoteURL }
        if (audio.isNotEmpty()) p["audio"] = jsonStrings(audio)
        val photos = d.attachments.filter { !it.isAudio && it.remoteURL != null }.map { a ->
            if (a.alt.isEmpty()) JsonPrimitive(a.remoteURL) else JsonObject(mapOf("value" to JsonPrimitive(a.remoteURL), "alt" to JsonPrimitive(a.alt)))
        }.toMutableList<JsonElement>()
        val external = d.field("photo-url")
        if (external.isNotEmpty()) { WebUrl.parse(external); photos += JsonPrimitive(external) }
        if (photos.isNotEmpty() && d.kind != PostKind.ARTICLE) p["photo"] = JsonArray(photos)
        return nested("h-" + hType(d.kind), p)
    }

    private fun dataUrl(a: Attachment) = "data:${a.mimeType};base64," + Base64.getEncoder().encodeToString(a.data)

    fun articleMarkdown(d: Draft): String {
        fun escape(value: String) = value.replace("]", "\\]").replace("\n", " ")
        val images = d.attachments.filter { !it.isAudio }.map { "![${escape(it.alt)}](${it.remoteURL ?: dataUrl(it)})" }.toMutableList()
        WebUrl.parseOrNull(d.fields["photo-url"])?.let { images += "![]($it)" }
        return (listOf(d.content.trim()) + images).filter { it.isNotEmpty() }.joinToString("\n\n")
    }

    fun articleHTML(d: Draft): String {
        var html = d.content.replace(Regex("<img\\b[^>]*quill-attachment:[^>]*>", RegexOption.IGNORE_CASE), "")
        var images = d.attachments.filter { !it.isAudio }.joinToString("") {
            "<figure><img src=\"${Html.escape(it.remoteURL ?: dataUrl(it))}\" alt=\"${Html.escape(it.alt)}\"></figure>"
        }
        WebUrl.parseOrNull(d.fields["photo-url"])?.let { images += "<figure><img src=\"${Html.escape(it)}\" alt=\"\"></figure>" }
        val body = Regex("</body>", RegexOption.IGNORE_CASE).find(html)
        html = if (body != null) html.substring(0, body.range.first) + images + html.substring(body.range.first) else html + images
        return html
    }

    /** A Micropub update that replaces or deletes only the properties changed since the post was fetched. */
    fun update(d: Draft, @Suppress("UNUSED_PARAMETER") preferences: Preferences = Preferences()): JsonObject {
        val url = d.editURL ?: throw QuillException("No post URL to update.")
        if (!d.kind.isEditable) throw QuillException("This post type does not support updating.")
        if (d.kind.targetProperty != null) WebUrl.parse(d.target)
        val original = d.original ?: emptyMap()
        val replace = linkedMapOf<String, JsonElement>()
        val removed = mutableListOf<String>()
        for ((key, value) in d.editableValues.toSortedMap()) {
            if (value == original[key].orEmpty()) continue
            if (value.isBlank()) { if (original[key].orEmpty().isNotEmpty()) removed += key; continue }
            when (key) {
                "category" -> replace[key] = jsonStrings(value.split(',').map { it.trim() }.filter { it.isNotEmpty() })
                "content" -> if (d.isHTML) replace[key] = JsonArray(listOf(JsonObject(mapOf("html" to JsonPrimitive(value))))) else {
                    replace[key] = jsonStrings(listOf(value))
                    if (d.kind == PostKind.CODE) replace["p3k-content-type"] = jsonStrings(listOf("code/" + (d.fields["language"] ?: "text")))
                    else d.fields["p3k-content-type"]?.takeIf { it.isNotEmpty() }?.let { replace["p3k-content-type"] = jsonStrings(listOf(it)) }
                }
                else -> replace[key] = jsonStrings(listOf(value))
            }
        }
        if (replace.isEmpty() && removed.isEmpty()) throw QuillException("Nothing has changed.")
        val body = linkedMapOf<String, JsonElement>("action" to JsonPrimitive("update"), "url" to JsonPrimitive(url))
        if (replace.isNotEmpty()) body["replace"] = JsonObject(replace)
        if (removed.isNotEmpty()) body["delete"] = jsonStrings(removed)
        return JsonObject(body)
    }
}
