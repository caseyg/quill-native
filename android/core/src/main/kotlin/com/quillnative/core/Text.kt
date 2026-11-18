package com.quillnative.core

import kotlinx.serialization.json.JsonElement
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** ISO 8601 dates with a time zone, as posts store them. */
object Iso8601 {
    private val output = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssXXX")

    fun parse(value: String?): Instant? {
        if (value.isNullOrBlank()) return null
        return runCatching { OffsetDateTime.parse(value.trim(), DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant() }.getOrNull()
    }

    fun parseOffset(value: String?): OffsetDateTime? =
        if (value.isNullOrBlank()) null else runCatching { OffsetDateTime.parse(value.trim(), DateTimeFormatter.ISO_OFFSET_DATE_TIME) }.getOrNull()

    fun format(instant: Instant, zone: ZoneId = ZoneOffset.UTC): String = output.format(instant.atZone(zone))
}

object Html {
    private val entities = listOf(
        "&nbsp;" to " ", "&lt;" to "<", "&gt;" to ">", "&quot;" to "\"", "&#39;" to "'", "&#x27;" to "'", "&rsquo;" to "’",
        "&lsquo;" to "‘", "&ldquo;" to "“", "&rdquo;" to "”", "&hellip;" to "…", "&mdash;" to "—", "&ndash;" to "–", "&amp;" to "&",
    )
    private val opt = setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)

    /** Visible text of an HTML fragment, with block elements as line breaks. */
    fun text(html: String): String {
        var s = html.replace(Regex("<(script|style)\\b[^>]*>.*?</\\1>", opt), "")
        s = s.replace(Regex("<(br|/p|/div|/li|/h[1-6]|/blockquote|/figure)\\b[^>]*>", RegexOption.IGNORE_CASE), "\n")
        s = s.replace(Regex("<[^>]+>"), "")
        for ((entity, character) in entities) s = s.replace(entity, character)
        s = s.replace(Regex("[ \\t]+"), " ")
        s = s.replace(Regex("\\s*\\n\\s*"), "\n")
        return s.trim()
    }

    /** True when the HTML is only paragraphs and line breaks, so plain text loses nothing. */
    fun isPlain(html: String): Boolean = !Regex("<(?!/?(p|br)\\b)[a-z/!]", RegexOption.IGNORE_CASE).containsMatchIn(html)

    fun escape(value: String): String = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    data class Image(val url: String, val alt: String)

    fun firstImage(html: String): Image? {
        val tag = Regex("<img\\b[^>]*>", RegexOption.IGNORE_CASE).find(html)?.value ?: return null
        fun attribute(name: String): String? {
            val m = Regex(name + "\\s*=\\s*(\"[^\"]*\"|'[^']*')", RegexOption.IGNORE_CASE).find(tag) ?: return null
            val raw = m.value.split("=", limit = 2)[1].trim()
            return text(raw.drop(1).dropLast(1))
        }
        val src = WebUrl.parseOrNull(attribute("src")) ?: return null
        return Image(src, attribute("alt").orEmpty())
    }
}

object Markdown {
    /** Readable text of Markdown source, for rows and search. */
    fun text(source: String): String {
        var s = source
        s = s.replace(Regex("!\\[([^\\]]*)\\]\\([^)]*\\)"), "$1")
        s = s.replace(Regex("\\[([^\\]]*)\\]\\([^)]*\\)"), "$1")
        s = s.replace(Regex("(?m)^\\s{0,3}(#{1,6}|>|[-*+]|\\d+\\.)\\s+"), "")
        s = s.replace(Regex("(\\*\\*|__|\\*|`)"), "")
        return s.trim()
    }
}

/** Small helpers for reading microformats2 JSON. */
object Mf2 {
    fun text(value: JsonElement?): String {
        val first = value.arr?.firstOrNull() ?: value ?: return ""
        first.str?.let { return it }
        val o = first.obj ?: return ""
        return o["value"].str ?: o["html"].str?.let(Html::text) ?: o["properties"].obj?.get("name")?.let { text(it) } ?: ""
    }

    fun url(value: JsonElement?): String? {
        val first = value.arr?.firstOrNull() ?: return null
        return first.str ?: first.obj?.get("properties").obj?.get("url").arr?.firstOrNull().str ?: first.obj?.get("value").str
    }

    data class Content(val text: String, val html: String?, val image: Html.Image?)

    /** Content as text, with HTML source when the server sent HTML. */
    fun content(value: JsonElement?): Content {
        val first = value.arr?.firstOrNull() ?: return Content("", null, null)
        first.str?.let { return Content(it, null, null) }
        val o = first.obj ?: return Content("", null, null)
        val html = o["html"].str
        return Content(o["value"].str ?: html?.let(Html::text) ?: "", html, html?.let(Html::firstImage))
    }

    fun date(value: String): Instant? {
        val v = value.trim()
        runCatching { return OffsetDateTime.parse(v, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant() }
        runCatching { return LocalDate.parse(v, DateTimeFormatter.ISO_LOCAL_DATE).atStartOfDay(ZoneOffset.UTC).toInstant() }
        // Some servers omit the "T" or the time zone.
        runCatching { return OffsetDateTime.parse(v, DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ssXXX")).toInstant() }
        runCatching { return LocalDateTime.parse(v, DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss")).atZone(ZoneId.systemDefault()).toInstant() }
        runCatching { return LocalDateTime.parse(v, DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")).atZone(ZoneId.systemDefault()).toInstant() }
        return null
    }
}
