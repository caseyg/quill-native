package com.quillnative.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SignInTest {
    @Test fun fullUrlDiscoversEverythingNeededForLogin() {
        val connection = blocking {
            SignInDiscovery.discover("  https://example.com/  ", Transport { req ->
                assertTrue(req.url.startsWith("https://"))
                if (path(req.url) == "/") ok(req, """<link rel="micropub" href="/micropub"><link rel="indieauth-metadata" href="/.well-known/oauth-authorization-server">""")
                else ok(req, """{"issuer":"https://example.com/","authorization_endpoint":"https://example.com/auth","token_endpoint":"https://example.com/auth/token","scopes_supported":["create","update","media","draft"]}""")
            })
        }
        assertEquals("https://example.com/", connection.me)
        assertEquals("https://example.com/auth", connection.authorizationEndpoint)
        assertEquals("https://example.com/auth/token", connection.tokenEndpoint)
        assertEquals("https://example.com/micropub", connection.micropub)
        assertEquals("create update media draft", connection.scopes)
    }

    private val legacy = Transport { req -> ok(req, "", headers = mapOf("Link" to "</auth>; rel=authorization_endpoint, </token>; rel=token_endpoint, </mp>; rel=micropub")) }

    @Test fun bareDomainSignsInOverHttps() {
        val connection = blocking { SignInDiscovery.discover(" example.com ", Transport { req -> assertEquals("https://example.com/", req.url); legacy.send(req) }) }
        assertEquals("https://example.com/", connection.me)
        assertEquals("https://example.com/mp", connection.micropub)
        assertEquals("https://example.com/token", connection.tokenEndpoint)
        assertNull(connection.issuer)
    }

    @Test fun invalidAddressIsRejectedBeforeAnyRequest() {
        val e = assertFails<QuillException> { blocking { SignInDiscovery.discover("not a site", Transport { throw AssertionError("no request") }) } }
        assertTrue(e.message!!.contains("URL"))
    }

    @Test fun missingEndpointsGiveActionableError() {
        val e = assertFails<QuillException> { blocking { SignInDiscovery.discover("https://example.com/", Transport { ok(it, "<html></html>") }) } }
        assertTrue(e.message!!.contains("advertise"))
    }

    @Test fun rejectsMetadataIssuerFromAnotherHost() {
        val e = assertFails<QuillException> {
            blocking {
                SignInDiscovery.discover("https://example.com/", Transport { req ->
                    if (path(req.url) == "/") ok(req, """<link rel="micropub" href="/mp"><link rel="indieauth-metadata" href="/metadata">""")
                    else ok(req, """{"issuer":"https://evil.example/","authorization_endpoint":"https://example.com/auth","token_endpoint":"https://example.com/token"}""")
                })
            }
        }
        assertTrue(e.message!!.contains("issuer"))
    }

    @Test fun indieAuthRoundTripUsesPkceAndChecksTheProfile() {
        val configuration = blocking { SignInDiscovery.discover("example.com", legacy) }
        val request = IndieAuthRequest.start(configuration, "https://caseyg.github.io/quill-native/")
        val params = query(request.authorizationURL)
        assertEquals("S256", params["code_challenge_method"])
        assertEquals(OAuth.REDIRECT, params["redirect_uri"])
        assertEquals(request.state, params["state"])
        val (account, token) = blocking {
            request.finish("quill-native://oauth?code=c&state=${request.state}", Transport { req ->
                val body = Form.decode(req.body!!.toString(Charsets.UTF_8)).toMap()
                assertEquals(request.verifier, body["code_verifier"])
                assertEquals("c", body["code"])
                ok(req, """{"access_token":"tok","token_type":"Bearer","me":"https://example.com/","scope":"create update"}""")
            })
        }
        assertEquals("tok", token)
        assertEquals("https://example.com/mp", account.micropub)
        assertTrue(account.permits("update"))
    }
}
