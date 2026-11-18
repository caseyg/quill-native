package com.quillnative.core

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI

class QuillException(message: String) : Exception(message)

data class Endpoints(
    val micropub: String,
    val authorization: String?,
    val token: String?,
)

data class Note(
    val content: String,
    val tags: List<String> = emptyList(),
)

/**
 * Minimal Micropub client: endpoint discovery and creating a note.
 * Uses HttpURLConnection so the same code runs on Android and on a plain JVM in tests.
 */
class MicropubClient(private val userAgent: String = "Quill Android") {

    /** Normalizes "example.com" to "https://example.com/". */
    fun normalize(site: String): String {
        val trimmed = site.trim()
        if (trimmed.isEmpty()) throw QuillException("Enter your website.")
        val withScheme = if (Regex("^https?://", RegexOption.IGNORE_CASE).containsMatchIn(trimmed)) trimmed else "https://$trimmed"
        val uri = runCatching { URI(withScheme) }.getOrNull()
        if (uri?.host.isNullOrEmpty()) throw QuillException("That doesn't look like a website address.")
        return if (uri!!.path.isNullOrEmpty()) "$withScheme/" else withScheme
    }

    fun discover(site: String): Endpoints {
        val url = normalize(site)
        val connection = open(url, "GET")
        try {
            val status = connection.responseCode
            if (status !in 200..299) throw QuillException("Your site answered with HTTP $status.")
            val finalUrl = connection.url.toString()
            val html = connection.inputStream.bufferedReader().use { it.readText() }
            val links = Discovery.parse(html, connection.getHeaderFields()["Link"]?.joinToString(","), finalUrl)
            val micropub = links["micropub"] ?: throw QuillException("Your site doesn't list a Micropub endpoint.")
            return Endpoints(micropub, links["authorization_endpoint"], links["token_endpoint"])
        } finally {
            connection.disconnect()
        }
    }

    /** Creates a note and returns the new post's URL from the Location header. */
    fun create(endpoint: String, token: String, note: Note): String {
        if (note.content.isBlank()) throw QuillException("Write something before publishing.")
        val pairs = mutableListOf("h" to "entry", "content" to note.content)
        note.tags.map(String::trim).filter(String::isNotEmpty).forEach { pairs += "category[]" to it }
        val connection = open(endpoint, "POST")
        try {
            connection.doOutput = true
            connection.setRequestProperty("Authorization", "Bearer $token")
            connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
            connection.outputStream.use { it.write(Form.encode(pairs).toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            if (status == 401 || status == 403) throw QuillException("Your site didn't accept the access token.")
            if (status !in 200..299) throw QuillException("Publishing failed with HTTP $status.")
            return connection.getHeaderField("Location") ?: throw QuillException("Published, but your site didn't return the post's address.")
        } finally {
            connection.disconnect()
        }
    }

    private fun open(url: String, method: String): HttpURLConnection {
        val connection = try {
            URI(url).toURL().openConnection() as HttpURLConnection
        } catch (e: IOException) {
            throw QuillException("Couldn't reach $url.")
        }
        connection.requestMethod = method
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.setRequestProperty("User-Agent", userAgent)
        connection.setRequestProperty("Accept", if (method == "GET") "text/html" else "application/json")
        return connection
    }
}
