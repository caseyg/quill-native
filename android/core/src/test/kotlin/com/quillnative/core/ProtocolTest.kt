package com.quillnative.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class ProtocolTest {
    private val endpoint = "https://example.com/mp"

    @Test fun discoveryAcceptsAttributeOrderAndRelativeLinks() {
        val links = Discovery.parse("<LINK href='/mp' rel='micropub alternate'><link rel=\"token_endpoint\" href=\"/token?a=1&amp;b=2\">", "</auth>; rel=\"authorization_endpoint\"", "https://example.com/profile")
        assertEquals("https://example.com/mp", links["micropub"])
        assertEquals("https://example.com/token?a=1&b=2", links["token_endpoint"])
        assertEquals("https://example.com/auth", links["authorization_endpoint"])
    }

    @Test fun callbackRejectsWrongStateAndMissingCode() {
        assertFails<QuillException> { OAuth.callback("quill-native://oauth?state=wrong&code=abc", "expected") }
        assertFails<QuillException> { OAuth.callback("quill-native://oauth?state=expected", "expected") }
        assertEquals("abc", OAuth.callback("quill-native://oauth?state=expected&code=abc", "expected"))
    }

    @Test fun issuerMismatchAndDuplicateStateAreRejected() {
        assertFails<QuillException> { OAuth.callback("quill-native://oauth?state=ok&code=abc&iss=https%3A%2F%2Fevil.example%2F", "ok", "https://example.com/") }
        assertFails<QuillException> { OAuth.callback("quill-native://oauth?state=ok&state=evil&code=abc", "ok") }
    }

    @Test fun formEncodingProtectsAmpersandsAndPlus() {
        assertEquals("content=a%2Bb%20%26%20c", Form.encode(mapOf("content" to "a+b & c")))
    }

    @Test fun createMissingLocationNeverClaimsSuccess() {
        val client = MicropubClient(endpoint, "secret", Transport { ok(it, "", 201) })
        val e = assertFails<QuillException> { blocking { client.create(Draft(kind = PostKind.NOTE, content = "A thought")) } }
        assertTrue(e.message!!.contains("Location"))
    }

    @Test fun createResolvesRelativeLocationAndSendsAuthorization() {
        val client = MicropubClient(endpoint, "secret", Transport { req ->
            assertEquals("Bearer secret", req.header("Authorization"))
            assertEquals("application/json", req.header("Content-Type"))
            ok(req, "", 201, mapOf("Location" to "/posts/1"))
        })
        assertEquals("https://example.com/posts/1", blocking { client.create(Draft(kind = PostKind.NOTE, content = "A thought")) })
    }

    @Test fun unauthorizedErrorDoesNotEchoTokenOrResponseBody() {
        val client = MicropubClient(endpoint, "secret", Transport { ok(it, "secret debug response", 401) })
        val e = assertFails<QuillException> { blocking { client.query("config") } }
        assertFalse(e.message!!.contains("secret"))
        assertTrue(e.message!!.contains("401"))
    }

    @Test fun multipartFallbackContainsPhotoAndContent() {
        val client = MicropubClient(endpoint, "secret", Transport { req ->
            assertTrue(req.header("Content-Type")!!.startsWith("multipart/form-data"))
            val body = req.body!!.toString(Charsets.UTF_8)
            assertTrue(body.contains("name=\"photo[0]\"; filename=\"image.jpg\""))
            assertTrue(body.contains("A photo"))
            ok(req, "", 201, mapOf("Location" to "/1"))
        })
        blocking { client.create(Draft(kind = PostKind.PHOTO, content = "A photo", attachments = listOf(Attachment(data = "image".toByteArray(), filename = "image.jpg", mimeType = "image/jpeg")))) }
    }

    @Test fun formEncodingFlattensNestedProperties() {
        var body = ""
        val client = MicropubClient(endpoint, "t", Transport { req -> body = req.body!!.toString(Charsets.UTF_8); ok(req, "", 201, mapOf("Location" to "/1")) })
        blocking { client.create(Draft(kind = PostKind.NOTE, content = "Hi", tags = "a, b"), Preferences(formEncoded = true)) }
        assertEquals("h=entry&category%5B0%5D=a&category%5B1%5D=b&content=Hi", body)
    }

    @Test fun configParsesCapabilities() {
        val config = ServerConfig.parse(parseJson("""{"media-endpoint":"https://example.com/media","syndicate-to":[{"uid":"social","name":"Social"}],"channels":["events"],"visibility":["public","private"],"post-types":[{"type":"note","name":"Note"}]}"""))
        assertEquals("Social", config.targets[0].name)
        assertEquals(listOf("events"), config.channels)
        assertEquals(listOf("note"), config.postTypes)
        assertEquals("https://example.com/media", config.mediaEndpoint)
    }

    @Test fun latestMediaCarriesPhotoTimeAndLocation() {
        val client = MicropubClient("https://example.com/media", "secret", Transport { req ->
            assertTrue(req.url.contains("q=source"))
            ok(req, """{"items":[{"url":"https://example.com/photo.jpg","published":"2026-11-13T14:30:00Z","latitude":40.7,"longitude":-74.0,"date_created":"2026-11-13T12:00:00Z"}]}""")
        })
        val item = blocking { client.latestMedia("https://example.com/media", Instant.parse("2026-11-13T14:35:00Z")) }
        assertEquals("https://example.com/photo.jpg", item?.url)
        assertEquals("geo:40.7,-74.0", item?.location)
        assertNull(blocking { client.latestMedia("https://example.com/media", Instant.parse("2026-11-14T14:35:00Z")) })
    }

    @Test fun codeUpdateOnlyReplacesEditableFields() {
        val value = Payload.update(Draft(kind = PostKind.CODE, content = "print(1)", editURL = "https://example.com/1"))
        assertEquals(setOf("content", "p3k-content-type"), value["replace"].obj!!.keys)
    }

    @Test fun redirectPolicyAllowsPublicCanonicalizationButProtectsTokens() {
        val original = HttpRequest("http://example.com/")
        assertTrue(Network.allowsRedirect(original, "https://www.example.com/"))
        assertFalse(Network.allowsRedirect(original.with("Authorization", "Bearer secret"), "https://www.example.com/"))
        assertFalse(Network.allowsRedirect(HttpRequest("https://www.example.com/"), "http://example.com/"))
    }

    @Test fun scopeNegotiationDoesNotRequestUnadvertisedDraftScope() {
        assertEquals("create update media", OAuth.requestedScopes(null))
        assertEquals("create update draft", OAuth.requestedScopes(listOf("create", "update", "draft")))
    }

    @Test fun httpLinkDiscoveryAllowsParametersBeforeRelAndQuotedCommas() {
        val links = Discovery.parse("", "</auth>; type=\"application/json\"; title=\"Auth, sign in\"; rel=\"authorization_endpoint\", </token>; type=\"application/json\"; rel=\"token_endpoint\"", "https://example.com/")
        assertEquals("https://example.com/auth", links["authorization_endpoint"])
        assertEquals("https://example.com/token", links["token_endpoint"])
    }
}
