package com.quillnative.core

/** A stretch of Markdown source that the editor shows with formatting, as character offsets. */
data class MarkdownSpan(val kind: Kind, val start: Int, val end: Int) {
    enum class Kind { HEADING1, HEADING2, HEADING3, QUOTE, CODE_BLOCK, STRONG, EMPHASIS, STRIKETHROUGH, CODE, LINK, MARKER }
}

/**
 * Finds the formatting in Markdown source so it can be styled in place, leaving the text as it is.
 * A line-based reading of CommonMark's common cases; the iOS app uses swift-markdown for the same job.
 */
object MarkdownStyle {
    private val heading = Regex("^(#{1,6})([ \\t]+)(.*)$")
    private val quote = Regex("^(\\s{0,3}>\\s?)(.*)$")
    private val fence = Regex("^\\s{0,3}(```|~~~)")
    private val inline = listOf(
        Regex("(`+)([^`\\n]+?)\\1") to MarkdownSpan.Kind.CODE,
        Regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1") to MarkdownSpan.Kind.STRONG,
        Regex("(~~)(?=\\S)(.+?)(?<=\\S)\\1") to MarkdownSpan.Kind.STRIKETHROUGH,
        Regex("(?<![*\\w])(\\*|_)(?=[^\\s*_])(.+?)(?<=[^\\s*_])\\1(?![*\\w])") to MarkdownSpan.Kind.EMPHASIS,
    )
    private val link = Regex("!?\\[([^\\]\\n]*)\\]\\(([^)\\n]*)\\)")

    fun spans(source: String): List<MarkdownSpan> {
        val spans = mutableListOf<MarkdownSpan>()
        var offset = 0
        var inFence = false
        var fenceStart = 0
        for (line in source.split('\n')) {
            val start = offset
            val end = offset + line.length
            offset = end + 1
            if (fence.containsMatchIn(line)) {
                if (!inFence) { inFence = true; fenceStart = start }
                else { inFence = false; spans += MarkdownSpan(MarkdownSpan.Kind.CODE_BLOCK, fenceStart, end) }
                continue
            }
            if (inFence) continue
            heading.find(line)?.let { m ->
                val level = m.groupValues[1].length
                val kind = when (level) { 1 -> MarkdownSpan.Kind.HEADING1; 2 -> MarkdownSpan.Kind.HEADING2; else -> MarkdownSpan.Kind.HEADING3 }
                spans += MarkdownSpan(kind, start, end)
                spans += MarkdownSpan(MarkdownSpan.Kind.MARKER, start, start + level + m.groupValues[2].length)
                inlineSpans(line, start, spans)
                return@let
            } ?: quote.find(line)?.let { m ->
                spans += MarkdownSpan(MarkdownSpan.Kind.QUOTE, start, end)
                spans += MarkdownSpan(MarkdownSpan.Kind.MARKER, start, start + m.groupValues[1].length)
                inlineSpans(line, start, spans)
            } ?: inlineSpans(line, start, spans)
        }
        if (inFence) spans += MarkdownSpan(MarkdownSpan.Kind.CODE_BLOCK, fenceStart, source.length)
        return spans
    }

    private fun inlineSpans(line: String, base: Int, spans: MutableList<MarkdownSpan>) {
        val taken = mutableListOf<IntRange>()
        fun free(range: IntRange) = taken.none { it.first <= range.last && range.first <= it.last }
        for (m in link.findAll(line)) {
            taken += m.range
            val textStart = m.range.first + (if (m.value.startsWith("!")) 2 else 1)
            val textEnd = textStart + m.groupValues[1].length
            spans += MarkdownSpan(MarkdownSpan.Kind.MARKER, base + m.range.first, base + textStart)
            spans += MarkdownSpan(MarkdownSpan.Kind.LINK, base + textStart, base + textEnd)
            spans += MarkdownSpan(MarkdownSpan.Kind.MARKER, base + textEnd, base + m.range.last + 1)
        }
        for ((regex, kind) in inline) {
            for (m in regex.findAll(line)) {
                if (!free(m.range)) continue
                if (kind == MarkdownSpan.Kind.CODE) taken += m.range
                val mark = m.groupValues[1].length
                spans += MarkdownSpan(kind, base + m.range.first + mark, base + m.range.last + 1 - mark)
                spans += MarkdownSpan(MarkdownSpan.Kind.MARKER, base + m.range.first, base + m.range.first + mark)
                spans += MarkdownSpan(MarkdownSpan.Kind.MARKER, base + m.range.last + 1 - mark, base + m.range.last + 1)
            }
        }
    }

    /** Wraps the selection in a marker such as `**`, or removes it when the selection is already wrapped. */
    fun wrap(text: String, start: Int, end: Int, mark: String): Triple<String, Int, Int> {
        val before = text.substring(0, start)
        val selected = text.substring(start, end)
        val after = text.substring(end)
        if (before.endsWith(mark) && after.startsWith(mark)) {
            return Triple(before.dropLast(mark.length) + selected + after.drop(mark.length), start - mark.length, end - mark.length)
        }
        return Triple(before + mark + selected + mark + after, start + mark.length, end + mark.length)
    }

    /** Cycles the current line through no heading, `#`, `##` and `###`. */
    fun heading(text: String, cursor: Int): Pair<String, Int> {
        val lineStart = text.lastIndexOf('\n', (cursor - 1).coerceAtLeast(0)).let { if (cursor == 0) 0 else it + 1 }
        val lineEnd = text.indexOf('\n', cursor).let { if (it < 0) text.length else it }
        val line = text.substring(lineStart, lineEnd)
        val level = Regex("^(#{1,6}) ").find(line)?.groupValues?.get(1)?.length ?: 0
        val body = line.replace(Regex("^#{1,6} "), "")
        val next = if (level >= 3) body else "#".repeat(level + 1) + " " + body
        val delta = next.length - line.length
        return text.substring(0, lineStart) + next + text.substring(lineEnd) to (cursor + delta).coerceIn(lineStart, lineStart + next.length)
    }

    /** Turns the selection into a link, or inserts one at the cursor. */
    fun link(text: String, start: Int, end: Int, url: String): Pair<String, Int> {
        val label = text.substring(start, end).ifEmpty { url }
        val inserted = "[$label]($url)"
        return text.substring(0, start) + inserted + text.substring(end) to start + inserted.length
    }
}
