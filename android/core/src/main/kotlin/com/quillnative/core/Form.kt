package com.quillnative.core

/** application/x-www-form-urlencoded, escaping everything but RFC 3986 unreserved characters (same as QuillCore's Form). */
object Form {
    fun encode(pairs: List<Pair<String, String>>): String =
        pairs.joinToString("&") { (key, value) -> escape(key) + "=" + escape(value) }

    private fun escape(text: String): String = buildString {
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            val c = byte.toInt().toChar()
            if (c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c in "-._~") append(c)
            else append('%').append("%02X".format(byte.toInt() and 0xFF))
        }
    }
}
