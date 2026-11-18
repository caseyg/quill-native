package com.quillnative.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DiscoveryTest {
    @Test fun findsHtmlLinksAndResolvesRelativeOnes() {
        val html = """<head><link rel="micropub" href="/micropub"><link href='https://auth.example/auth' rel="authorization_endpoint"></head>"""
        val links = Discovery.parse(html, null, "https://example.com/blog/")
        assertEquals("https://example.com/micropub", links["micropub"])
        assertEquals("https://auth.example/auth", links["authorization_endpoint"])
    }

    @Test fun headerWinsOverHtml() {
        val links = Discovery.parse("""<link rel="micropub" href="/html">""", """<https://example.com/header>; rel="micropub"""", "https://example.com/")
        assertEquals("https://example.com/header", links["micropub"])
    }

    @Test fun splitsHeaderLinksAndMultipleRels() {
        val header = """<https://a.example/token>; rel="token_endpoint", <https://a.example/mp?x=1,2>; rel="micropub media-endpoint""""
        val links = Discovery.parse("", header, "https://example.com/")
        assertEquals("https://a.example/token", links["token_endpoint"])
        assertEquals("https://a.example/mp?x=1,2", links["micropub"])
        assertEquals("https://a.example/mp?x=1,2", links["media-endpoint"])
    }

    @Test fun ignoresCommentsAndNonHttpLinks() {
        val html = """<!-- <link rel="micropub" href="/old"> --><link rel="token_endpoint" href="javascript:alert(1)">"""
        val links = Discovery.parse(html, null, "https://example.com/")
        assertNull(links["micropub"])
        assertNull(links["token_endpoint"])
    }

    @Test fun decodesAmpersands() {
        val links = Discovery.parse("""<link rel="micropub" href="/mp?a=1&amp;b=2">""", null, "https://example.com/")
        assertEquals("https://example.com/mp?a=1&b=2", links["micropub"])
    }
}
