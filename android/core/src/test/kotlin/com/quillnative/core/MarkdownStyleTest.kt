package com.quillnative.core

import com.quillnative.core.MarkdownSpan.Kind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownStyleTest {
    private fun styled(source: String, kind: Kind) = MarkdownStyle.spans(source).filter { it.kind == kind }.map { source.substring(it.start, it.end) }

    @Test fun headingsAndMarkers() {
        val source = "# Title\nBody\n## Sub"
        assertEquals(listOf("# Title"), styled(source, Kind.HEADING1))
        assertEquals(listOf("## Sub"), styled(source, Kind.HEADING2))
        assertTrue(styled(source, Kind.MARKER).containsAll(listOf("# ", "## ")))
    }

    @Test fun inlineFormatting() {
        val source = "A **bold** and *soft* and `co*de*` and ~~gone~~"
        assertEquals(listOf("bold"), styled(source, Kind.STRONG))
        assertEquals(listOf("soft"), styled(source, Kind.EMPHASIS))
        assertEquals(listOf("co*de*"), styled(source, Kind.CODE))
        assertEquals(listOf("gone"), styled(source, Kind.STRIKETHROUGH))
    }

    @Test fun linksQuotesAndFences() {
        val source = "> Quoted [text](https://example.com)\n```\nlet x = 1\n```\nafter"
        assertEquals(listOf("> Quoted [text](https://example.com)"), styled(source, Kind.QUOTE))
        assertEquals(listOf("text"), styled(source, Kind.LINK))
        assertEquals(listOf("```\nlet x = 1\n```"), styled(source, Kind.CODE_BLOCK))
    }

    @Test fun editingCommands() {
        assertEquals(Triple("a **b** c", 4, 5), MarkdownStyle.wrap("a b c", 2, 3, "**"))
        assertEquals(Triple("a b c", 2, 3), MarkdownStyle.wrap("a **b** c", 4, 5, "**"))
        assertEquals("# Line" to 3, MarkdownStyle.heading("Line", 1))
        assertEquals("### Line" to 5, MarkdownStyle.heading("## Line", 4))
        assertEquals("Line" to 0, MarkdownStyle.heading("### Line", 1))
        assertEquals("see [here](https://x.example)" to 29, MarkdownStyle.link("see here", 4, 8, "https://x.example"))
    }
}

class TagsTest {
    @Test fun addsRemovesAndSuggests() {
        assertEquals("a, b", Tags.add("a", "#b, A"))
        assertEquals("a", Tags.remove("a, b", "b"))
        val used = Tags.used(listOf(Post("https://e.example/1", PostKind.NOTE, categories = listOf("web", "Web", "https://p.example/"))), listOf(Draft(kind = PostKind.NOTE, tags = "food")))
        assertEquals(listOf("web", "food"), used)
        assertEquals(listOf("food"), Tags.suggestions("fo", "web", emptyList(), used))
    }
}
