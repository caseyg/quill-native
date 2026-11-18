package com.quillnative.core

/** What a web page says about itself: its title, summary, preview image and tags. */
data class LinkContext(val title: String, val description: String, val image: String? = null, val tags: List<String> = emptyList()) {
    companion object {
        suspend fun fetch(url: String, transport: Transport = Network.transport): LinkContext {
            val response = transport.send(HttpRequest(url, timeoutMillis = 15_000))
            Network.check(response)
            if (response.body.size >= 5_000_000) throw QuillException("This page is too large to preview.")
            return parse(response.text, response.url.ifEmpty { url })
        }

        fun parse(html: String, url: String): LinkContext {
            val meta = metaTags(html)
            fun first(vararg keys: String) = keys.firstNotNullOfOrNull { k -> meta[k]?.firstOrNull { it.isNotEmpty() } }.orEmpty()
            val og = first("og:title", "twitter:title")
            val title = og.ifEmpty { match("<title[^>]*>(.*?)</title>", html) }
            val image = WebUrl.resolve(url, first("og:image", "og:image:url", "twitter:image"))?.takeIf { first("og:image", "og:image:url", "twitter:image").isNotEmpty() }
            val tags = mutableListOf<String>()
            for (value in meta["article:tag"].orEmpty() + meta["keywords"].orEmpty().flatMap { it.split(',') }) {
                val tag = value.trim()
                if (tag.isNotEmpty() && tag.length <= 40 && tags.none { it.equals(tag, ignoreCase = true) }) tags += tag
            }
            return LinkContext(
                title = title.ifEmpty { WebUrl.host(url) ?: url },
                description = first("og:description", "description", "twitter:description"),
                image = WebUrl.parseOrNull(image),
                tags = tags.take(10),
            )
        }

        /** `<meta>` values by `property` or `name`, lowercased, in page order. */
        private fun metaTags(html: String): Map<String, List<String>> {
            val result = mutableMapOf<String, MutableList<String>>()
            val attribute = Regex("([a-zA-Z:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")
            for (found in Regex("<meta\\b[^>]*>", RegexOption.IGNORE_CASE).findAll(html)) {
                val values = mutableMapOf<String, String>()
                for (pair in attribute.findAll(found.value)) {
                    values[pair.groupValues[1].lowercase()] = decode(pair.groups[2]?.value ?: pair.groups[3]?.value ?: "")
                }
                val key = values["property"] ?: values["name"] ?: continue
                val content = values["content"] ?: continue
                result.getOrPut(key.lowercase()) { mutableListOf() } += content
            }
            return result
        }

        private fun match(pattern: String, html: String): String {
            val found = Regex(pattern, setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)).find(html) ?: return ""
            return decode(found.groupValues[1].replace(Regex("<[^>]+>"), ""))
        }

        private fun decode(value: String): String {
            var text = value
            for ((entity, character) in listOf("&quot;" to "\"", "&#39;" to "'", "&#x27;" to "'", "&apos;" to "'", "&lt;" to "<", "&gt;" to ">", "&nbsp;" to " ", "&amp;" to "&")) {
                text = text.replace(entity, character)
            }
            return text.trim()
        }
    }
}
