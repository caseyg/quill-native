package com.quillnative.core

/** application/x-www-form-urlencoded, escaping everything but RFC 3986 unreserved characters (same as QuillCore's Form). */
object Form {
    fun encode(values: Map<String, String>): String = encode(values.toSortedMap().map { it.key to it.value })

    fun encode(pairs: List<Pair<String, String>>): String =
        pairs.joinToString("&") { (key, value) -> escape(key) + "=" + escape(value) }

    fun escape(text: String): String = buildString {
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            val c = byte.toInt().toChar()
            if (c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c in "-._~") append(c)
            else append('%').append("%02X".format(byte.toInt() and 0xFF))
        }
    }

    /** Pairs from a query string or form body. */
    fun decode(text: String): List<Pair<String, String>> = text.removePrefix("?").split('&').filter { it.isNotEmpty() }.map {
        val parts = it.split('=', limit = 2)
        fun d(s: String) = java.net.URLDecoder.decode(s, "UTF-8")
        d(parts[0]) to d(parts.getOrElse(1) { "" })
    }
}
