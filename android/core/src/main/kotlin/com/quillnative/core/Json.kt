package com.quillnative.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

/** Shared JSON settings: tolerant when reading, compact when writing. */
val QuillJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
    coerceInputValues = true
}

val JsonElement?.obj: JsonObject? get() = this as? JsonObject
val JsonElement?.arr: JsonArray? get() = this as? JsonArray
/** The string value, or null for numbers, booleans, null and containers. */
val JsonElement?.str: String? get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
val JsonElement?.num: Double? get() = (this as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
val JsonElement?.bool: Boolean? get() = (this as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

fun parseJson(text: String): JsonElement? = runCatching { QuillJson.parseToJsonElement(text) }.getOrNull()

internal fun jsonString(value: String) = JsonPrimitive(value)
internal fun jsonStrings(values: List<String>) = JsonArray(values.map(::JsonPrimitive))

/** A number as JSON, written without a fractional part when it is whole, as Foundation's encoder does. */
internal fun jsonNumber(value: Double): JsonPrimitive =
    if (value.isFinite() && value == Math.rint(value) && kotlin.math.abs(value) < 1e15) JsonPrimitive(value.toLong()) else JsonPrimitive(value)

/** A number's text for form encoding. */
internal fun numberText(value: Double): String =
    if (value.isFinite() && value == Math.rint(value) && kotlin.math.abs(value) < 1e15) value.toLong().toString() else value.toString()

internal fun nested(type: String, properties: Map<String, JsonElement>): JsonObject =
    JsonObject(mapOf("type" to jsonStrings(listOf(type)), "properties" to JsonObject(properties)))

/** Pretty JSON with sorted keys, for showing a request. */
fun prettyJson(value: JsonElement, indent: String = ""): String {
    val next = "$indent  "
    return when (value) {
        is JsonObject -> if (value.isEmpty()) "{}" else value.entries.sortedBy { it.key }
            .joinToString(",\n", "{\n", "\n$indent}") { (k, v) -> next + JsonPrimitive(k).toString() + " : " + prettyJson(v, next) }
        is JsonArray -> if (value.isEmpty()) "[]" else value.joinToString(",\n", "[\n", "\n$indent]") { next + prettyJson(it, next) }
        JsonNull -> "null"
        is JsonPrimitive -> value.toString().replace("\\/", "/")
    }
}
