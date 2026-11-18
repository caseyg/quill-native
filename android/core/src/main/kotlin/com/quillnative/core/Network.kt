package com.quillnative.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.UUID

class HttpRequest(
    val url: String,
    val method: String = "GET",
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray? = null,
    val timeoutMillis: Int = 60_000,
) {
    fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
    fun with(name: String, value: String) = HttpRequest(url, method, headers + (name to value), body, timeoutMillis)
}

class HttpResponse(
    val status: Int,
    /** The address the body came from, after redirects. */
    val url: String,
    val headers: Map<String, List<String>> = emptyMap(),
    val body: ByteArray = ByteArray(0),
) {
    fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value?.joinToString(", ")
    val text: String get() = body.toString(Charsets.UTF_8)
}

/** Sends a request. Tests replace it; the app uses [Network.send]. */
fun interface Transport {
    suspend fun send(request: HttpRequest): HttpResponse
}

object Network {
    /** Refuse authenticated redirects to a different origin; do not forward bearer tokens. */
    fun allowsRedirect(original: HttpRequest, to: String): Boolean {
        val from = runCatching { URI(original.url) }.getOrNull() ?: return false
        val next = runCatching { URI(to) }.getOrNull() ?: return false
        if (next.scheme !in setOf("https", "http")) return false
        if (from.scheme == "https" && next.scheme != "https") return false
        if (original.header("Authorization") != null || original.method == "POST") {
            return from.scheme == next.scheme && from.host == next.host && port(from) == port(next)
        }
        return true
    }

    private fun port(uri: URI) = if (uri.port != -1) uri.port else if (uri.scheme == "https") 443 else 80

    val transport = Transport { request -> send(request, Int.MAX_VALUE) }

    suspend fun send(request: HttpRequest): HttpResponse = send(request, Int.MAX_VALUE)

    /** Reads at most `limit` bytes of the body, refusing early when the server announces more. */
    suspend fun send(request: HttpRequest, limit: Int): HttpResponse = withContext(Dispatchers.IO) {
        var current = request
        repeat(10) {
            val response = once(current, limit)
            val location = response.header("Location")
            if (response.status in setOf(301, 302, 303, 307, 308) && location != null) {
                val next = WebUrl.resolve(response.url, location) ?: return@withContext response
                if (!allowsRedirect(request, next)) return@withContext response
                // 303, and 301/302 after POST, turn into GET as browsers do.
                val get = response.status == 303 || (response.status in setOf(301, 302) && current.method == "POST")
                current = if (get) HttpRequest(next, "GET", current.headers.filterKeys { !it.equals("Content-Type", true) }, null, current.timeoutMillis)
                else HttpRequest(next, current.method, current.headers, current.body, current.timeoutMillis)
                return@repeat
            }
            return@withContext response
        }
        throw QuillException("Your site redirected too many times.")
    }

    private fun once(request: HttpRequest, limit: Int): HttpResponse {
        val connection = try {
            URI(request.url).toURL().openConnection() as HttpURLConnection
        } catch (e: Exception) {
            throw QuillException("That address can’t be opened.")
        }
        try {
            connection.instanceFollowRedirects = false
            connection.requestMethod = request.method
            connection.connectTimeout = minOf(request.timeoutMillis, 20_000)
            connection.readTimeout = request.timeoutMillis
            connection.useCaches = false
            if (request.header("User-Agent") == null) connection.setRequestProperty("User-Agent", "Quill for Android")
            for ((k, v) in request.headers) connection.setRequestProperty(k, v)
            request.body?.let { body ->
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            if (connection.contentLengthLong > limit) throw QuillException("This page is too large.")
            val stream: InputStream? = if (status >= 400) connection.errorStream else runCatching { connection.inputStream }.getOrNull()
            val body = stream?.use { read(it, limit) } ?: ByteArray(0)
            val headers = connection.headerFields.filterKeys { it != null }.mapKeys { it.key!! }
            return HttpResponse(status, connection.url.toString(), headers, body)
        } catch (e: QuillException) {
            throw e
        } catch (e: IOException) {
            throw QuillException("Couldn’t reach ${WebUrl.host(request.url) ?: "the server"}. Check your connection.")
        } finally {
            connection.disconnect()
        }
    }

    private fun read(stream: InputStream, limit: Int): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (out.size() < limit) {
            val n = stream.read(buffer, 0, minOf(buffer.size, limit - out.size()))
            if (n < 0) break
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }

    fun check(response: HttpResponse) {
        if (response.status !in 200..299) {
            val hint = if (response.status == 401 || response.status == 403) "Check your sign-in and granted permissions." else "Your draft is safe. Check the site before retrying."
            throw QuillException("Your site returned HTTP ${response.status}. $hint", response.status)
        }
    }
}

class Multipart(val boundary: String = "Quill-" + UUID.randomUUID().toString().uppercase()) {
    private val out = ByteArrayOutputStream()
    val data: ByteArray get() = out.toByteArray()
    val contentType: String get() = "multipart/form-data; boundary=$boundary"

    private fun text(value: String) = out.write(value.toByteArray(Charsets.UTF_8))
    private fun safe(s: String) = s.replace("\r", "").replace("\n", "").replace("\"", "_")

    fun field(name: String, value: String) = text("--$boundary\r\nContent-Disposition: form-data; name=\"${safe(name)}\"\r\n\r\n$value\r\n")

    fun file(name: String, attachment: Attachment) {
        text("--$boundary\r\nContent-Disposition: form-data; name=\"${safe(name)}\"; filename=\"${safe(attachment.filename)}\"\r\nContent-Type: ${safe(attachment.mimeType)}\r\n\r\n")
        out.write(attachment.data); text("\r\n")
    }

    fun finish() = text("--$boundary--\r\n")
}
