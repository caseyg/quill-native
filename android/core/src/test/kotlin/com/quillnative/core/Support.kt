package com.quillnative.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

fun ok(request: HttpRequest, body: String, status: Int = 200, headers: Map<String, String> = emptyMap()) =
    HttpResponse(status, request.url, headers.mapValues { listOf(it.value) }, body.toByteArray())

fun <T> blocking(block: suspend () -> T): T = runBlocking { block() }

fun strings(vararg values: String): JsonElement = JsonArray(values.map(::JsonPrimitive))
fun obj(vararg pairs: Pair<String, JsonElement>) = JsonObject(mapOf(*pairs))

fun query(url: String): Map<String, String> = Form.decode(url.substringAfter('?', "")).toMap()
fun path(url: String): String = java.net.URI(url).path

inline fun <reified T : Throwable> assertFails(block: () -> Unit): T {
    try { block() } catch (e: Throwable) { if (e is T) return e; throw AssertionError("Expected ${T::class.simpleName}, got $e", e) }
    throw AssertionError("Expected ${T::class.simpleName}")
}
