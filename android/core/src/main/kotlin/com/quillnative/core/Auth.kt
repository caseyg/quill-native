package com.quillnative.core

import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

object OAuth {
    const val REDIRECT = "quill-native://oauth"

    fun requestedScopes(supported: List<String>?): String {
        val base = listOf("create", "update", "media")
        if (supported == null) return base.joinToString(" ")
        return (base + listOf("draft", "delete")).filter { it in supported }.joinToString(" ")
    }

    /** The authorization code from the redirect back to the app, after checking it belongs to this sign-in. */
    fun callback(url: String, expectedState: String, expectedIssuer: String? = null): String {
        val uri = runCatching { URI(url) }.getOrNull()
        if (uri == null || uri.scheme != "quill-native" || uri.host != "oauth") throw QuillException("Unexpected sign-in callback.")
        val items = Form.decode(uri.rawQuery.orEmpty())
        if (items.map { it.first }.toSet().size != items.size) throw QuillException("Sign-in returned duplicate parameters.")
        fun value(name: String) = items.firstOrNull { it.first == name }?.second
        if (value("state") != expectedState) throw QuillException("Sign-in state did not match. Please try again.")
        if (expectedIssuer != null && value("iss") != expectedIssuer) throw QuillException("Sign-in returned an unexpected authorization server.")
        if (value("error") != null) throw QuillException("Your site declined sign-in.")
        val code = value("code")
        if (code.isNullOrEmpty()) throw QuillException("Sign-in returned no authorization code.")
        return code
    }
}

data class SignInConfiguration(
    val inputURL: String,
    val me: String,
    val authorizationEndpoint: String,
    val tokenEndpoint: String,
    val micropub: String,
    val issuer: String?,
    val scopes: String,
)

object SignInDiscovery {
    /** Discover endpoints from a website address. A bare domain is treated as HTTPS. */
    suspend fun discover(site: String, transport: Transport = Network.transport): SignInConfiguration {
        val input = WebUrl.site(site)
        val response = transport.send(HttpRequest(input, timeoutMillis = 20_000))
        Network.check(response)
        val me = WebUrl.site(response.url.ifEmpty { input })
        val links = Discovery.parse(response.text, response.header("Link"), me)
        var issuer: String? = null
        var scopes = OAuth.requestedScopes(null)
        var authorization = links["authorization_endpoint"]
        var token = links["token_endpoint"]
        links["indieauth-metadata"]?.let { metadata ->
            val metaUri = URI(metadata)
            if (metaUri.scheme != "https") throw QuillException("Sign-in metadata must use HTTPS.")
            val res = transport.send(HttpRequest(metadata, timeoutMillis = 20_000))
            Network.check(res)
            val value = parseJson(res.text).obj ?: throw QuillException("Your site returned invalid sign-in metadata.")
            issuer = value["issuer"].str
            val issuerUri = issuer?.let { runCatching { URI(it) }.getOrNull() }
            if (issuerUri == null || issuerUri.scheme != "https" || issuerUri.host != metaUri.host || issuerUri.port != metaUri.port ||
                issuerUri.rawQuery != null || issuerUri.rawFragment != null || !metaUri.path.startsWith(issuerUri.path.orEmpty())) {
                throw QuillException("The discovered authorization server metadata has an invalid issuer.")
            }
            scopes = OAuth.requestedScopes(value["scopes_supported"].arr?.mapNotNull { it.str })
            authorization = WebUrl.parseOrNull(value["authorization_endpoint"].str) ?: authorization
            token = WebUrl.parseOrNull(value["token_endpoint"].str) ?: token
        }
        val micropub = links["micropub"]
        if (authorization == null || token == null || micropub == null) {
            throw QuillException("Your site must advertise IndieAuth sign-in and token endpoints and a Micropub endpoint.")
        }
        if (listOf(authorization!!, token!!, micropub).any { !it.startsWith("https://") }) throw QuillException("Sign-in requires HTTPS endpoints.")
        return SignInConfiguration(input, me, authorization!!, token!!, micropub, issuer, scopes)
    }
}

/** One IndieAuth sign-in in progress: PKCE values and the address to open in the browser. */
data class IndieAuthRequest(
    val configuration: SignInConfiguration,
    val clientId: String,
    val state: String,
    val verifier: String,
    val authorizationURL: String,
) {
    companion object {
        private val random = SecureRandom()
        private fun token(bytes: Int = 32): String = ByteArray(bytes).also(random::nextBytes).let { Base64.getUrlEncoder().withoutPadding().encodeToString(it) }

        fun start(configuration: SignInConfiguration, clientId: String): IndieAuthRequest {
            val client = WebUrl.parse(clientId)
            val state = token()
            val verifier = token(48)
            val challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
            val pairs = listOf(
                "me" to configuration.me, "client_id" to client, "redirect_uri" to OAuth.REDIRECT, "state" to state,
                "response_type" to "code", "scope" to configuration.scopes, "code_challenge" to challenge, "code_challenge_method" to "S256",
            )
            val base = configuration.authorizationEndpoint
            val url = base + (if ('?' in base) "&" else "?") + Form.encode(pairs)
            return IndieAuthRequest(configuration, client, state, verifier, url)
        }
    }

    /** Trades the code from the redirect for a token, and confirms which site it signed in. */
    suspend fun finish(callback: String, transport: Transport = Network.transport): Pair<Account, String> {
        val code = OAuth.callback(callback, state, configuration.issuer)
        val body = Form.encode(mapOf(
            "grant_type" to "authorization_code", "code" to code, "client_id" to clientId, "redirect_uri" to OAuth.REDIRECT,
            "me" to configuration.me, "code_verifier" to verifier,
        ))
        val response = transport.send(HttpRequest(configuration.tokenEndpoint, "POST",
            mapOf("Content-Type" to "application/x-www-form-urlencoded", "Accept" to "application/json"), body.toByteArray()))
        Network.check(response)
        val values: Map<String, String> = parseJson(response.text).obj?.let { o -> o.mapNotNull { (k, v) -> v.str?.let { k to it } }.toMap() }
            ?: Form.decode(response.text).toMap()
        val accessToken = values["access_token"]
        val returnedMe = values["me"]?.let { runCatching { WebUrl.site(it) }.getOrNull() }
        if (accessToken.isNullOrEmpty() || values["token_type"]?.lowercase() != "bearer" || returnedMe == null) throw QuillException("Your site didn’t return a valid token.")
        var endpoint = configuration.micropub
        if (returnedMe != configuration.me) {
            // IndieAuth lets a server return a more specific profile URL, provided it names the same authorization server.
            val confirmed = SignInDiscovery.discover(returnedMe, transport)
            if (confirmed.authorizationEndpoint != configuration.authorizationEndpoint) throw QuillException("Your site signed in a different address.")
            endpoint = confirmed.micropub
        }
        return Account(returnedMe, endpoint, configuration.tokenEndpoint, values["scope"].orEmpty()) to accessToken
    }
}

object TokenSignIn {
    /** Signs in with a token the person pasted: finds the Micropub endpoint and checks the token works. */
    suspend fun discover(site: String, token: String, transport: Transport = Network.transport): Pair<Account, ServerConfig> {
        val me = WebUrl.site(site)
        if (!me.startsWith("https://")) throw QuillException("Token sign-in needs an https site.")
        val response = transport.send(HttpRequest(me)); Network.check(response)
        val links = Discovery.parse(response.text, response.header("Link"), response.url.ifEmpty { me })
        val endpoint = links["micropub"]?.takeIf { it.startsWith("https://") } ?: throw QuillException("No Micropub endpoint found on this site.")
        val config = MicropubClient(endpoint, token, transport).configuration()
        return Account(me, endpoint, links["token_endpoint"], "create update delete media draft") to config
    }

    /** Asks the site to revoke a token, when it has a token endpoint. Failures are ignored. */
    suspend fun revoke(account: Account, token: String, transport: Transport = Network.transport) {
        val endpoint = account.tokenEndpoint ?: return
        runCatching {
            transport.send(HttpRequest(endpoint, "POST", mapOf("Content-Type" to "application/x-www-form-urlencoded"),
                Form.encode(mapOf("action" to "revoke", "token" to token)).toByteArray()))
        }
    }
}
