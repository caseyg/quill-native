package com.quillnative.core

import com.sun.net.httpserver.HttpServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import java.net.InetSocketAddress

class MicropubClientTest {
    private lateinit var server: HttpServer
    private var lastBody = ""
    private var lastAuthorization: String? = null
    private val base get() = "http://localhost:${server.address.port}"

    @Before fun start() {
        server = HttpServer.create(InetSocketAddress("localhost", 0), 0)
        server.createContext("/") { exchange ->
            val page = """<link rel="micropub" href="/micropub"><link rel="token_endpoint" href="/token">""".toByteArray()
            exchange.responseHeaders.add("Link", "<$base/auth>; rel=\"authorization_endpoint\"")
            exchange.sendResponseHeaders(200, page.size.toLong()); exchange.responseBody.use { it.write(page) }
        }
        server.createContext("/micropub") { exchange ->
            lastBody = exchange.requestBody.bufferedReader().readText()
            lastAuthorization = exchange.requestHeaders.getFirst("Authorization")
            if (lastAuthorization != "Bearer good") { exchange.sendResponseHeaders(401, -1); exchange.close(); return@createContext }
            exchange.responseHeaders.add("Location", "$base/posts/1")
            exchange.sendResponseHeaders(201, -1); exchange.close()
        }
        server.start()
    }

    @After fun stop() = server.stop(0)

    @Test fun discoversEndpoints() {
        val endpoints = MicropubClient().discover(base)
        assertEquals("$base/micropub", endpoints.micropub)
        assertEquals("$base/token", endpoints.token)
        assertEquals("$base/auth", endpoints.authorization)
    }

    @Test fun createsNote() {
        val location = MicropubClient().create("$base/micropub", "good", Note("Hello, café & friends", listOf("indieweb", " ", "android")))
        assertEquals("$base/posts/1", location)
        assertEquals("h=entry&content=Hello%2C%20caf%C3%A9%20%26%20friends&category%5B%5D=indieweb&category%5B%5D=android", lastBody)
    }

    @Test fun reportsRejectedToken() {
        val error = assertThrows(QuillException::class.java) { MicropubClient().create("$base/micropub", "bad", Note("Hi")) }
        assertEquals("Your site didn't accept the access token.", error.message)
    }

    @Test fun normalizesBareDomains() {
        assertEquals("https://example.com/", MicropubClient().normalize(" example.com "))
        assertEquals("http://localhost:8765/", MicropubClient().normalize("http://localhost:8765"))
        assertThrows(QuillException::class.java) { MicropubClient().normalize("") }
    }
}
