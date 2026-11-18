package com.quillnative.android

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.quillnative.core.Draft
import com.quillnative.core.Iso8601
import com.quillnative.core.Leg
import com.quillnative.core.PostKind
import java.time.Instant
import java.time.ZoneId

/** Form groups for the post types that are records rather than prose. */
fun LazyListScope.structuredFields(draft: Draft, weightUnit: String, update: (Draft) -> Unit) {
    fun field(name: String) = draft.field(name)
    fun set(name: String) = { value: String -> update(draft.withField(name, value)) }
    when (draft.kind) {
        PostKind.WEIGHT -> item {
            Group { FieldRow("Weight", field("weight"), "0", set("weight"), keyboard = KeyboardType.Decimal, suffix = weightUnit) }
        }
        PostKind.EXERCISE -> item {
            Group {
                FieldRow("Activity", field("activity"), "Running", set("activity"), words = true)
                RowDivider()
                FieldRow("Minutes", field("minutes"), "0", set("minutes"), keyboard = KeyboardType.Decimal)
                RowDivider()
                FieldRow("Heart Rate", field("heartrate"), "0", set("heartrate"), keyboard = KeyboardType.Decimal, suffix = "bpm")
            }
        }
        PostKind.EVENT -> {
            item {
                Group {
                    FieldRow("Name", draft.title, "Event", { update(draft.copy(title = it)) }, words = true)
                    RowDivider()
                    DateRow("Starts", field("start"), set("start"))
                    RowDivider()
                    val ends = field("end").isNotEmpty()
                    SwitchRow("Ends", ends) { on ->
                        update(draft.withField("end", if (on) Iso8601.format(Instant.now().plusSeconds(3600), ZoneId.systemDefault()) else ""))
                    }
                    AnimatedVisibility(ends) { Column { RowDivider(); DateRow("Ends", field("end"), set("end")) } }
                }
            }
            item { Group { PlainField(draft.content, { update(draft.copy(content = it)) }, "Description", Modifier.fillMaxWidth(), singleLine = false, minLines = 3) } }
            item {
                Disclosure("Place") {
                    FieldRow("Name", field("place-name"), "", set("place-name"), words = true); RowDivider()
                    FieldRow("Street", field("place-street-address"), "", set("place-street-address"), words = true); RowDivider()
                    FieldRow("City", field("place-locality"), "", set("place-locality"), words = true); RowDivider()
                    FieldRow("Region", field("place-region"), "", set("place-region"), words = true); RowDivider()
                    FieldRow("Country", field("place-country-name"), "", set("place-country-name"), words = true); RowDivider()
                    FieldRow("Website", field("place-url"), "", set("place-url"), keyboard = KeyboardType.Uri)
                }
            }
            item {
                Disclosure("Conference") {
                    FieldRow("Name", field("conference-name"), "", set("conference-name"), words = true); RowDivider()
                    FieldRow("Website", field("conference-url"), "", set("conference-url"), keyboard = KeyboardType.Uri); RowDivider()
                    FieldRow("Slides", field("slides"), "", set("slides"), keyboard = KeyboardType.Uri); RowDivider()
                    PlainField(field("slides-embed"), set("slides-embed"), "Slides Embed", Modifier.fillMaxWidth(), words = false, singleLine = false); RowDivider()
                    FieldRow("Video", field("video-link"), "", set("video-link"), keyboard = KeyboardType.Uri); RowDivider()
                    PlainField(field("video-embed"), set("video-embed"), "Video Embed", Modifier.fillMaxWidth(), words = false, singleLine = false)
                }
            }
        }
        PostKind.REVIEW -> {
            item {
                Group {
                    FieldRow("Item", field("item-name"), "", set("item-name"), words = true); RowDivider()
                    FieldRow("URL", field("item-url"), "", set("item-url"), keyboard = KeyboardType.Uri); RowDivider()
                    StarRating(field("rating"), set("rating"))
                }
            }
            item {
                Group {
                    PlainField(field("summary"), set("summary"), "Summary", Modifier.fillMaxWidth()); RowDivider()
                    PlainField(draft.content, { update(draft.copy(content = it)) }, "Review", Modifier.fillMaxWidth(), singleLine = false, minLines = 4)
                }
            }
        }
        PostKind.ITINERARY -> {
            items(draft.legs.size, key = { draft.legs[it].id }) { index ->
                val leg = draft.legs[index]
                LegEditor(leg, canRemove = draft.legs.size > 1,
                    onChange = { changed -> update(draft.copy(legs = draft.legs.map { if (it.id == leg.id) changed else it })) },
                    onRemove = { update(draft.copy(legs = draft.legs.filter { it.id != leg.id })) })
            }
            item { Group { ActionRow("Add Leg", trailing = { Icon(Icons.Outlined.Add, null) }) { update(draft.copy(legs = draft.legs + Leg())) } } }
        }
        else -> {}
    }
}

@Composable
private fun Disclosure(title: String, content: @Composable () -> Unit) {
    var open by rememberSaveable { mutableStateOf(false) }
    Group {
        ActionRow(title, trailing = { Icon(if (open) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null) }) { open = !open }
        AnimatedVisibility(open) { Column { RowDivider(); content() } }
    }
}

@Composable
private fun StarRating(value: String, onChange: (String) -> Unit) {
    val rating = value.toDoubleOrNull()?.toInt() ?: 0
    val haptics = LocalHapticFeedback.current
    Row(
        Modifier.fillMaxWidth().padding(8.dp).semantics { contentDescription = "Rating"; stateDescription = "$rating of 5" },
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        for (star in 1..5) {
            IconButton(onClick = { haptics.performHapticFeedback(HapticFeedbackType.SegmentTick); onChange(star.toString()) }) {
                Icon(if (star <= rating) Icons.Outlined.Star else Icons.Outlined.StarBorder, "$star stars",
                    tint = if (star <= rating) Color(0xFFFFC107) else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(30.dp))
            }
        }
    }
}

private val modes = listOf("air" to "Air", "train" to "Train", "bus" to "Bus", "boat" to "Boat", "car" to "Car", "walk" to "Walk")

@Composable
private fun LegEditor(leg: Leg, canRemove: Boolean, onChange: (Leg) -> Unit, onRemove: () -> Unit) {
    Group {
        PickerRow("Mode", leg.transitType, modes) { onChange(leg.copy(transitType = it)) }; RowDivider()
        FieldRow("Operator", leg.operatorName, "", { onChange(leg.copy(operatorName = it)) }, words = true); RowDivider()
        FieldRow("Number", leg.number, "", { onChange(leg.copy(number = it)) }); RowDivider()
        FieldRow("From", leg.origin, "", { onChange(leg.copy(origin = it)) }, words = true); RowDivider()
        FieldRow("To", leg.destination, "", { onChange(leg.copy(destination = it)) }, words = true); RowDivider()
        DateRow("Departs", leg.departure) { onChange(leg.copy(departure = it)) }; RowDivider()
        DateRow("Arrives", leg.arrival) { onChange(leg.copy(arrival = it)) }
        if (canRemove) { RowDivider(); ActionRow("Remove Leg", color = MaterialTheme.colorScheme.error, onClick = onRemove) }
    }
}
