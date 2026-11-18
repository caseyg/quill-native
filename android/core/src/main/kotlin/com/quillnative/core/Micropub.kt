package com.quillnative.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.URI
import java.time.Duration
import java.time.Instant

@Serializable
data class SyndicationTarget(val uid: String, val name: String)

@Serializable
data class ServerConfig(
    val mediaEndpoint: String? = null,
    val targets: List<SyndicationTarget> = emptyList(),
    val channels: List<String> = emptyList(),
    val visibility: List<String> = emptyList(),
    val postTypes: List<String> = emptyList(),
) {
    companion object {
        fun parse(value: JsonElement?): ServerConfig {
            val o = value.obj ?: return ServerConfig()
            return ServerConfig(
                mediaEndpoint = WebUrl.parseOrNull(o["media-endpoint"].str),
                targets = o["syndicate-to"].arr.orEmpty().mapNotNull { item ->
                    val t = item.obj ?: return@mapNotNull null
                    val uid = t["uid"].str ?: t["target"].str ?: return@mapNotNull null
                    SyndicationTarget(uid, t["name"].str ?: t["target"].str ?: uid)
                },
                channels = o["channels"].arr.orEmpty().mapNotNull { it.str ?: it.obj?.get("uid").str },
                visibility = o["visibility"].arr.orEmpty().mapNotNull { it.str },
                postTypes = o["post-types"].arr.orEmpty().mapNotNull { it.obj?.get("type").str },
            )
        }
    }
}

data class MediaItem(val url: String, val published: String?, val location: String?)

class MicropubClient(val endpoint: String, private val token: String, private val transport: Transport = Network.transport) {
    private fun request(url: String, method: String = "GET", contentType: String? = null, body: ByteArray? = null): HttpRequest {
        val headers = mutableMapOf("Authorization" to "Bearer $token", "Accept" to "application/json")
        contentType?.let { headers["Content-Type"] = it }
        return HttpRequest(url, method, headers, body)
    }

    private fun withQuery(base: String, pairs: List<Pair<String, String>>): String {
        val uri = URI(base)
        val existing = uri.rawQuery?.takeIf { it.isNotEmpty() }
        val added = Form.encode(pairs)
        val query = listOfNotNull(existing, added.takeIf { it.isNotEmpty() }).joinToString("&")
        val head = base.substringBefore('#').substringBefore('?')
        return if (query.isEmpty()) head else "$head?$query"
    }

    suspend fun query(q: String, parameters: Map<String, String> = emptyMap()): String {
        val response = transport.send(request(withQuery(endpoint, listOf("q" to q) + parameters.toList())))
        Network.check(response)
        return response.text
    }

    suspend fun configuration(): ServerConfig {
        var config = ServerConfig.parse(parseJson(query("config")) ?: throw QuillException("Your site returned an invalid configuration."))
        if (config.targets.isEmpty()) runCatching { ServerConfig.parse(parseJson(query("syndicate-to"))) }.getOrNull()?.let { config = config.copy(targets = it.targets) }
        if (config.channels.isEmpty()) runCatching { ServerConfig.parse(parseJson(query("channels"))) }.getOrNull()?.let { config = config.copy(channels = it.channels) }
        return config
    }

    /** Tags the site already uses, from Micropub's category query. */
    suspend fun categories(): List<String> {
        val value = parseJson(query("category")) ?: return emptyList()
        return value.obj?.get("categories").arr.orEmpty().mapNotNull { it.str ?: it.obj?.get("name").str }
    }

    suspend fun latestMedia(mediaEndpoint: String, now: Instant = Instant.now()): MediaItem? {
        val response = transport.send(request(withQuery(mediaEndpoint, listOf("q" to "source", "limit" to "1"))))
        Network.check(response)
        val item = parseJson(response.text).obj?.get("items").arr?.firstOrNull().obj ?: return null
        val url = WebUrl.parseOrNull(item["url"].str) ?: return null
        val published = item["published"].str?.let { Iso8601.parse(it) }
        if (published != null && Duration.between(published, now).seconds > 900) return null
        fun number(key: String): String? = item[key].str ?: item[key].num?.toString()
        val lat = number("latitude"); val lon = number("longitude")
        return MediaItem(url, item["date_created"].str, if (lat != null && lon != null) "geo:$lat,$lon" else null)
    }

    suspend fun upload(attachment: Attachment, mediaEndpoint: String): String {
        val form = Multipart(); form.file("file", attachment); form.finish()
        val response = transport.send(request(mediaEndpoint, "POST", form.contentType, form.data))
        Network.check(response)
        return location(response)
    }

    suspend fun create(draft: Draft, preferences: Preferences = Preferences()): String {
        val payload = Payload.create(draft, preferences)
        val pending = draft.attachments.filter { it.remoteURL == null }
        val req = if (pending.isNotEmpty() || preferences.formEncoded) {
            val properties = payload["properties"].obj ?: JsonObject(emptyMap())
            val pairs = mutableListOf("h" to Payload.hType(draft.kind))
            for ((key, value) in properties.toSortedMap()) flatten(key, value, pairs)
            if (pending.isEmpty()) {
                request(endpoint, "POST", "application/x-www-form-urlencoded", Form.encode(pairs).toByteArray())
            } else {
                val form = Multipart()
                for ((name, value) in pairs) form.field(name, value)
                pending.filter { !it.isAudio }.forEachIndexed { i, a -> form.file("photo[$i]", a); if (a.alt.isNotEmpty()) form.field("photo-alt[$i]", a.alt) }
                pending.filter { it.isAudio }.forEachIndexed { i, a -> form.file("audio[$i]", a) }
                form.finish()
                request(endpoint, "POST", form.contentType, form.data)
            }
        } else {
            request(endpoint, "POST", "application/json", payload.toString().toByteArray())
        }
        val response = transport.send(req)
        Network.check(response)
        return location(response)
    }

    private fun flatten(name: String, value: JsonElement, pairs: MutableList<Pair<String, String>>) {
        when (value) {
            is JsonArray -> value.forEachIndexed { i, item -> flatten(if (value.size == 1) name else "$name[$i]", item, pairs) }
            is JsonObject -> for ((k, v) in value) flatten("$name[$k]", v, pairs)
            is JsonPrimitive -> when {
                value.isString -> pairs += name to value.content
                value.num != null -> pairs += name to numberText(value.num!!)
            }
            else -> {}
        }
    }

    suspend fun update(draft: Draft, preferences: Preferences = Preferences()): String {
        val response = transport.send(request(endpoint, "POST", "application/json", Payload.update(draft, preferences).toString().toByteArray()))
        Network.check(response)
        return if (response.header("Location") != null) location(response) else draft.editURL!!
    }

    private fun location(response: HttpResponse): String {
        val value = response.header("Location")
        val url = value?.let { WebUrl.resolve(response.url.ifEmpty { endpoint }, it) }
        return WebUrl.parseOrNull(url) ?: throw QuillException(
            "The server accepted the request but returned no valid Location header. It may have published. Check your site before retrying; your draft is retained.")
    }

    /** A draft for editing a post. */
    suspend fun source(url: String): Draft {
        // p3k-content-type asks Quill-compatible servers for Markdown source instead of rendered HTML.
        val text = query("source", linkedMapOf("url" to url, "p3k-content-type" to "text/markdown"))
        return DraftSource.from(parseJson(text) ?: throw QuillException("The source response is not JSON."), url)
    }

    suspend fun delete(url: String) {
        val body = JsonObject(mapOf("action" to JsonPrimitive("delete"), "url" to JsonPrimitive(url)))
        val response = transport.send(request(endpoint, "POST", "application/json", body.toString().toByteArray()))
        Network.check(response)
    }

    /** One page of the Micropub `q=source` list. Returns null when the server doesn't offer listing. */
    suspend fun posts(limit: Int = 100, after: String? = null): PostPage? {
        val parameters = linkedMapOf("limit" to limit.toString())
        if (after != null) parameters["after"] = after
        val text = try { query("source", parameters) } catch (e: QuillException) {
            if (e.status in setOf(400, 404, 405, 422, 501)) return null else throw e
        }
        val value = parseJson(text).obj ?: return null
        val items = value["items"].arr ?: return null
        val next = value["paging"].obj?.get("after").str
        return PostPage(items.mapNotNull { Post.fromMf2(it) }, next?.takeIf { it.isNotEmpty() })
    }
}
