package com.quillnative.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.URLEncoder
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Base64

/** A repository the signed-in person can write to. */
@Serializable
data class GitHubRepository(val fullName: String, val isPrivate: Boolean) {
    companion object {
        fun fromApi(value: JsonElement?): GitHubRepository? {
            val o = value.obj ?: return null
            val name = o["full_name"].str ?: return null
            // Only repositories the token can write to.
            val push = o["permissions"].obj?.get("push")
            if (push != null && push.bool != true) return null
            return GitHubRepository(name, o["private"].bool != false)
        }
    }
}

/** The code a person enters on github.com to let the app write for them. */
data class GitHubDeviceCode(val deviceCode: String, val userCode: String, val verificationURL: String, val interval: Int, val expires: Long)

/** The person declined on GitHub. */
class GitHubDeclined : Exception("Declined on GitHub.")

/**
 * Sign-in with GitHub's device flow, which needs only the app's public client ID and no secret.
 * https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
 */
class GitHubDeviceFlow(private val transport: Transport = Network.transport, private val now: () -> Long = System::currentTimeMillis) {
    suspend fun start(clientId: String, scope: String = "repo"): GitHubDeviceCode {
        val value = post("https://github.com/login/device/code", mapOf("client_id" to clientId, "scope" to scope))
        val deviceCode = value["device_code"].str
        val userCode = value["user_code"].str
        val verification = value["verification_uri"].str
        if (deviceCode == null || userCode == null || verification == null || !verification.startsWith("https://")) {
            throw QuillException(value["error_description"].str ?: "GitHub didn’t start sign-in.")
        }
        return GitHubDeviceCode(deviceCode, userCode, verification, maxOf(5, number(value["interval"]) ?: 5),
            now() + 1000L * (number(value["expires_in"]) ?: 900))
    }

    /** Waits until the person approves the code on GitHub, then returns the token. */
    suspend fun token(clientId: String, code: GitHubDeviceCode): String {
        var interval = code.interval
        while (now() < code.expires) {
            delay(interval * 1000L)
            val value = try {
                post("https://github.com/login/oauth/access_token", mapOf(
                    "client_id" to clientId, "device_code" to code.deviceCode, "grant_type" to "urn:ietf:params:oauth:grant-type:device_code"))
            } catch (e: CancellationException) {
                throw e
            } catch (e: QuillException) {
                // The connection dropped, often while the app was in the background. Ask again.
                if (e.status == null) continue else throw e
            }
            value["access_token"].str?.takeIf { it.isNotEmpty() }?.let { return it }
            when (value["error"].str) {
                "authorization_pending" -> continue
                "slow_down" -> interval = maxOf(interval + 5, number(value["interval"]) ?: 0)
                "access_denied" -> throw GitHubDeclined()
                "expired_token" -> throw QuillException("The code expired. Try again.")
                else -> throw QuillException(value["error_description"].str ?: "GitHub didn’t finish sign-in.")
            }
        }
        throw QuillException("The code expired. Try again.")
    }

    private fun number(value: JsonElement?): Int? = value.num?.toInt() ?: value.str?.toIntOrNull()

    private suspend fun post(url: String, form: Map<String, String>): JsonObject {
        val response = transport.send(HttpRequest(url, "POST",
            mapOf("Accept" to "application/json", "Content-Type" to "application/x-www-form-urlencoded"), Form.encode(form).toByteArray()))
        val value = parseJson(response.text).obj ?: JsonObject(emptyMap())
        // Errors such as a disabled device flow come back as 4xx with a JSON body.
        if (response.status !in 200..299 && value["error"] == null) throw QuillException("GitHub returned HTTP ${response.status}.", response.status)
        return value
    }
}

/** The few REST calls that keep drafts in a repository. */
class GitHubClient(val token: String, private val transport: Transport = Network.transport) {
    suspend fun login(): String = call("GET", "/user").obj?.get("login").str ?: throw QuillException("GitHub didn’t say who you are.")

    /** Repositories the person can push to, most recently pushed first. */
    suspend fun repositories(): List<GitHubRepository> {
        val all = mutableListOf<GitHubRepository>()
        for (page in 1..5) {
            val items = call("GET", "/user/repos?per_page=100&sort=pushed&page=$page").arr.orEmpty()
            all += items.mapNotNull { GitHubRepository.fromApi(it) }
            if (items.size < 100) break
        }
        return all
    }

    suspend fun repository(fullName: String): GitHubRepository =
        GitHubRepository.fromApi(call("GET", "/repos/$fullName")) ?: throw QuillException("GitHub can’t find $fullName.")

    suspend fun createPrivateRepository(name: String): GitHubRepository {
        val body = JsonObject(mapOf("name" to JsonPrimitive(name), "private" to JsonPrimitive(true), "auto_init" to JsonPrimitive(true),
            "description" to JsonPrimitive("Drafts from Quill")))
        return GitHubRepository.fromApi(call("POST", "/user/repos", body)) ?: throw QuillException("GitHub didn’t create the repository.")
    }

    /** The blob SHA of a file, or null when there is none. */
    suspend fun sha(path: String, repository: String): String? = try {
        call("GET", contents(path, repository)).obj?.get("sha").str
    } catch (e: QuillException) {
        if (e.status == 404) null else throw e
    }

    /** Creates or replaces a file and returns its new SHA. An out-of-date SHA is looked up and the write tried once more, since the app's copy wins. */
    suspend fun put(path: String, data: ByteArray, message: String, sha: String?, repository: String): String {
        suspend fun write(sha: String?): String {
            val body = mutableMapOf<String, JsonElement>("message" to JsonPrimitive(message), "content" to JsonPrimitive(Base64.getEncoder().encodeToString(data)))
            if (sha != null) body["sha"] = JsonPrimitive(sha)
            return call("PUT", contents(path, repository), JsonObject(body)).obj?.get("content").obj?.get("sha").str ?: throw QuillException("GitHub didn’t save $path.")
        }
        return try { write(sha) } catch (e: QuillException) {
            if (e.status == 409 || e.status == 422) write(sha(path, repository)) else throw e
        }
    }

    suspend fun delete(path: String, message: String, sha: String?, repository: String) {
        suspend fun remove(sha: String) { call("DELETE", contents(path, repository), JsonObject(mapOf("message" to JsonPrimitive(message), "sha" to JsonPrimitive(sha)))) }
        try {
            val current = sha ?: sha(path, repository) ?: return
            remove(current)
        } catch (e: QuillException) {
            when (e.status) {
                404 -> return
                409, 422 -> sha(path, repository)?.let { remove(it) }
                else -> throw e
            }
        }
    }

    private fun contents(path: String, repository: String) =
        "/repos/$repository/contents/" + path.split('/').joinToString("/") { URLEncoder.encode(it, "UTF-8").replace("+", "%20") }

    private suspend fun call(method: String, path: String, body: JsonElement? = null): JsonElement {
        val headers = mutableMapOf("Authorization" to "Bearer $token", "Accept" to "application/vnd.github+json", "X-GitHub-Api-Version" to "2022-11-28")
        if (body != null) headers["Content-Type"] = "application/json"
        val response = transport.send(HttpRequest("https://api.github.com$path", method, headers, body?.toString()?.toByteArray()))
        if (response.status !in 200..299) {
            val message = parseJson(response.text).obj?.get("message").str
            throw when {
                response.status == 401 -> QuillException("Your GitHub sign-in has expired. Sign in again.", 401)
                response.status == 403 && response.header("x-ratelimit-remaining") == "0" -> QuillException("GitHub’s rate limit was reached. Drafts will sync later.", 403)
                else -> QuillException("GitHub returned HTTP ${response.status}" + (message?.let { ": $it" } ?: "."), response.status)
            }
        }
        return if (response.body.isEmpty()) JsonNull else parseJson(response.text) ?: JsonNull
    }
}

/** What has been written to a repository for each draft, so that saving a draft sends only what changed. */
@Serializable
data class DraftMirror(
    val repository: String,
    val folder: String,
    /** Keyed by draft ID. */
    val drafts: Map<String, Entry> = emptyMap(),
) {
    @Serializable
    data class Entry(
        /** The SHA-256 of the Markdown file last written. */
        val digest: String = "",
        /** Path to blob SHA for each file written for the draft. */
        val files: Map<String, String> = emptyMap(),
    )

    /** One draft's changes: files to write, files to remove, and the digest to record once they are done. */
    data class Step(
        val id: String,
        val title: String,
        /** Attachments first, so the Markdown file never points at a file that isn't there yet. */
        val writes: List<Pair<String, ByteArray>>,
        val removals: List<Pair<String, String>>,
        /** Null when the draft is gone and its files are removed. */
        val digest: String?,
    ) {
        val removesDraft: Boolean get() = digest == null
    }

    /** The writes and removals that make the repository match these drafts. */
    fun plan(drafts: List<Draft>): List<Step> {
        val steps = mutableListOf<Step>()
        for (draft in drafts) {
            val entry = this.drafts[draft.id] ?: Entry()
            val markdown = DraftExport.markdown(draft)
            val digest = DraftExport.digest(markdown)
            val paths = DraftExport.paths(draft, folder)
            // Attachments never change once added, so only new ones are sent.
            val writes = paths.attachments.zip(draft.attachments).filter { entry.files[it.first] == null }.map { it.first to it.second.data }.toMutableList()
            if (digest != entry.digest || entry.files[paths.markdown] == null) writes += paths.markdown to markdown.toByteArray()
            val current = (listOf(paths.markdown) + paths.attachments).toSet()
            val removals = entry.files.filterKeys { it !in current }.toSortedMap().map { it.key to it.value }
            if (writes.isNotEmpty() || removals.isNotEmpty()) steps += Step(draft.id, draft.displayTitle, writes, removals, digest)
        }
        val kept = drafts.map { it.id }.toSet()
        for ((key, entry) in this.drafts.toSortedMap()) {
            if (key in kept) continue
            val title = entry.files.keys.firstOrNull { it.endsWith(".md") }?.substringAfterLast('/') ?: key
            steps += Step(key, title, emptyList(), entry.files.toSortedMap().map { it.key to it.value }, null)
        }
        return steps
    }

    fun wrote(path: String, sha: String, id: String): DraftMirror {
        val entry = drafts[id] ?: Entry()
        return copy(drafts = drafts + (id to entry.copy(files = entry.files + (path to sha))))
    }

    fun removed(path: String, id: String): DraftMirror {
        val entry = drafts[id] ?: return this
        return copy(drafts = drafts + (id to entry.copy(files = entry.files - path)))
    }

    /** Records that every file of a step is done. */
    fun finished(step: Step): DraftMirror =
        if (step.digest != null) copy(drafts = drafts + (step.id to (drafts[step.id] ?: Entry()).copy(digest = step.digest))) else copy(drafts = drafts - step.id)

    companion object {
        fun create(repository: String, folder: String) = DraftMirror(repository, normalize(folder))

        fun normalize(folder: String): String =
            folder.split('/').map { it.trim() }.filter { it.isNotEmpty() && it != "." && it != ".." }.joinToString("/")
    }
}

/** How a draft looks in a repository: a Markdown file with YAML front matter, plus its photos and recordings beside it. */
object DraftExport {
    data class Paths(val markdown: String, val attachments: List<String>)

    fun paths(draft: Draft, folder: String): Paths {
        val prefix = if (folder.isEmpty()) "" else "$folder/"
        val short = draft.id.take(8).lowercase()
        // Named by title only, since a name taken from the body would change, and move the file, with each edit.
        val name = slug(draft.title).ifEmpty { draft.kind.raw }
        val attachments = draft.attachments.map { prefix + "media/$short-${it.id.take(8).lowercase()}.${fileExtension(it)}" }
        return Paths("$prefix$name-$short.md", attachments)
    }

    fun markdown(draft: Draft): String {
        val lines = mutableListOf("---", "type: ${draft.kind.raw}")
        fun add(key: String, value: String) { if (value.isNotBlank()) lines += "$key: ${quote(value)}" }
        add("title", draft.title)
        add("target", draft.target)
        if (draft.tagList.isNotEmpty()) lines += "tags: [" + draft.tagList.joinToString(", ") { quote(it) } + "]"
        add("slug", draft.slug)
        add("published", draft.published)
        add("visibility", draft.visibility)
        add("channel", draft.channel)
        add("location", draft.location)
        if (draft.syndication.isNotEmpty()) lines += "syndicate-to: [" + draft.syndication.joinToString(", ") { quote(it) } + "]"
        if (draft.remoteDraft) lines += "post-status: draft"
        if (draft.isHTML) lines += "html: true"
        val fields = draft.fields.filter { it.value.isNotEmpty() }.toSortedMap()
        if (fields.isNotEmpty()) {
            lines += "fields:"
            lines += fields.map { "  ${quote(it.key)}: ${quote(it.value)}" }
        }
        if (draft.legs.isNotEmpty()) {
            lines += "legs:"
            for (leg in draft.legs) {
                val values = listOf("transit-type" to leg.transitType, "operator" to leg.operatorName, "number" to leg.number, "origin" to leg.origin,
                    "destination" to leg.destination, "departure" to leg.departure, "arrival" to leg.arrival).filter { it.second.isNotEmpty() }
                lines += "  - {" + values.joinToString(", ") { "${quote(it.first)}: ${quote(it.second)}" } + "}"
            }
        }
        if (draft.attachments.isNotEmpty()) {
            lines += "attachments:"
            for ((attachment, path) in draft.attachments.zip(paths(draft, "").attachments)) {
                lines += "  - file: ${quote(path)}"
                lines += "    type: ${quote(attachment.mimeType)}"
                if (attachment.alt.isNotEmpty()) lines += "    alt: ${quote(attachment.alt)}"
                attachment.remoteURL?.let { lines += "    url: ${quote(it)}" }
            }
        }
        draft.editURL?.let { add("edits", it) }
        draft.accountURL?.let { add("site", it) }
        lines += "---"
        val body = draft.content.trim('\n', '\r')
        return lines.joinToString("\n") + "\n" + (if (body.isEmpty()) "" else "\n$body\n")
    }

    fun digest(markdown: String): String =
        MessageDigest.getInstance("SHA-256").digest(markdown.toByteArray()).joinToString("") { "%02x".format(it) }

    /** A double-quoted YAML string. JSON's string escapes are valid YAML. */
    fun quote(value: String): String = JsonPrimitive(value).toString()

    fun slug(value: String): String {
        val folded = Normalizer.normalize(value, Normalizer.Form.NFKD).replace(Regex("\\p{M}+"), "").lowercase()
        val result = StringBuilder()
        for (c in folded) {
            if (c in 'a'..'z' || c in '0'..'9') result.append(c)
            else if (result.isNotEmpty() && !result.endsWith("-")) result.append('-')
            if (result.length >= 50) break
        }
        return result.toString().trim('-')
    }

    fun fileExtension(attachment: Attachment): String {
        val named = attachment.filename.substringAfterLast('.', "").lowercase()
        if (named.isNotEmpty() && named.all { it in 'a'..'z' || it in '0'..'9' }) return named
        return when (attachment.mimeType.lowercase()) {
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/heic" -> "heic"
            "image/gif" -> "gif"
            "audio/mp4", "audio/m4a", "audio/x-m4a" -> "m4a"
            else -> "bin"
        }
    }
}
