package com.quillnative.core

import java.net.URI

/** Finds rel links (micropub, authorization_endpoint, token_endpoint, ...) in a page's Link header and HTML. Ported from QuillCore's Discovery. */
object Discovery {
    private val linkTag = Regex("<link\\b[^>]*>", RegexOption.IGNORE_CASE)
    private val attribute = Regex("([\\w-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
    private val headerLink = Regex("^\\s*<([^>]+)>(.*)$", RegexOption.DOT_MATCHES_ALL)
    private val relParameter = Regex("^\\s*rel\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)'|([^\\s]+))\\s*$", RegexOption.IGNORE_CASE)
    private val comment = Regex("<!--[\\s\\S]*?-->")

    fun parse(html: String, linkHeader: String?, baseUrl: String): Map<String, String> {
        val result = linkedMapOf<String, String>()
        val base = URI(baseUrl)
        fun insert(rawHref: String, rel: String) {
            val href = rawHref.replace("&amp;", "&").replace("&#38;", "&").trim()
            val url = runCatching { base.resolve(URI(href)) }.getOrNull() ?: return
            if (url.scheme?.lowercase() !in setOf("http", "https")) return
            for (key in rel.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }) result.putIfAbsent(key, url.toString())
        }
        // Header discovery takes precedence over HTML discovery.
        for (segment in splitHeader(linkHeader.orEmpty(), ',')) {
            val link = headerLink.find(segment) ?: continue
            for (parameter in splitHeader(link.groupValues[2], ';')) {
                val rel = relParameter.find(parameter) ?: continue
                insert(link.groupValues[1], rel.groupValues.drop(1).firstOrNull { it.isNotEmpty() }.orEmpty())
            }
        }
        for (tag in linkTag.findAll(html.replace(comment, ""))) {
            val attrs = attribute.findAll(tag.value).associate { match ->
                match.groupValues[1].lowercase() to match.groupValues.drop(2).firstOrNull { it.isNotEmpty() }.orEmpty()
            }
            val href = attrs["href"] ?: continue
            val rel = attrs["rel"] ?: continue
            insert(href, rel)
        }
        return result
    }

    private fun splitHeader(value: String, separator: Char): List<String> {
        val parts = mutableListOf<String>()
        val current = StringBuilder()
        var quote: Char? = null
        var escaped = false
        var angle = false
        for (character in value) {
            if (escaped) { escaped = false; current.append(character); continue }
            val active = quote
            if (active != null) {
                current.append(character)
                if (character == '\\') escaped = true else if (character == active) quote = null
                continue
            }
            when (character) {
                '"', '\'' -> quote = character
                '<' -> angle = true
                '>' -> angle = false
            }
            if (character == separator && !angle) { parts += current.toString(); current.clear() } else current.append(character)
        }
        parts += current.toString()
        return parts
    }
}
