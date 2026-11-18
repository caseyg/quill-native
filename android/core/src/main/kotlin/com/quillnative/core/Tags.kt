package com.quillnative.core

/** Tag lists as the composer and share sheet edit them. */
object Tags {
    fun add(tags: String, value: String): String {
        val list = Draft(kind = PostKind.NOTE, tags = tags).tagList.toMutableList()
        for (part in value.split(',')) {
            val tag = part.trim().replace("#", "")
            if (tag.isNotEmpty() && list.none { it.equals(tag, ignoreCase = true) }) list += tag
        }
        return list.joinToString(", ")
    }

    fun remove(tags: String, tag: String): String = Draft(kind = PostKind.NOTE, tags = tags).tagList.filter { it != tag }.joinToString(", ")

    /** Tags used on the site, most used first, from posts and drafts. Person tags, which are URLs, are left out. */
    fun used(posts: List<Post>, drafts: List<Draft>): List<String> {
        val counts = mutableMapOf<String, Int>()
        val names = mutableMapOf<String, String>()
        for (raw in posts.flatMap { it.categories } + drafts.flatMap { it.tags.split(',') }) {
            val tag = raw.trim()
            if (tag.isEmpty() || tag.startsWith("http")) continue
            val key = tag.lowercase()
            counts[key] = (counts[key] ?: 0) + 1
            names.putIfAbsent(key, tag)
        }
        return counts.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key }).mapNotNull { names[it.key] }
    }

    /** Page tags first, then the site's own, filtered by what is being typed. */
    fun suggestions(input: String, current: String, page: List<String>, known: List<String>, limit: Int = 12): List<String> {
        val query = input.trim().lowercase()
        val used = Draft(kind = PostKind.NOTE, tags = current).tagList.map { it.lowercase() }.toSet()
        val seen = mutableSetOf<String>()
        return (page + known).filter { tag ->
            val key = tag.lowercase()
            key !in used && seen.add(key) && (query.isEmpty() || key.startsWith(query) || key.contains(" $query"))
        }.take(limit)
    }
}
