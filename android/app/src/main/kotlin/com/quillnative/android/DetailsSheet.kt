package com.quillnative.android

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.quillnative.core.ContentFormat
import com.quillnative.core.Draft
import com.quillnative.core.Payload
import com.quillnative.core.PostKind
import com.quillnative.core.prettyJson
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/** Everything about a post that is not its words: tags, timing, visibility, place. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailsSheet(store: AppStore, draft: Draft, htmlSource: Boolean, onHtmlSource: (Boolean) -> Unit, update: (Draft) -> Unit, onDismiss: () -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    var showingRequest by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet) {
        AnimatedContent(showingRequest, label = "details") { request ->
            if (request) RequestView(draft, store) { showingRequest = false }
            else DetailsForm(store, draft, htmlSource, onHtmlSource, update, onRequest = { showingRequest = true }, onDone = {
                // Hides with the sheet's own animation.
                onDismiss()
            })
        }
    }
}

@Composable
private fun DetailsForm(store: AppStore, draft: Draft, htmlSource: Boolean, onHtmlSource: (Boolean) -> Unit, update: (Draft) -> Unit, onRequest: () -> Unit, onDone: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var loadingLatest by remember { mutableStateOf(false) }
    val config = store.config
    LazyColumn(Modifier.fillMaxWidth()) {
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Details", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                TextButton(onClick = onDone) { Text("Done") }
            }
        }
        item {
            Group {
                Box(Modifier.testTag("details.tags")) { FieldRow("Tags", draft.tags, "one, two", { update(draft.copy(tags = it)) }) }
                RowDivider()
                FieldRow("Slug", draft.slug, "Automatic", { update(draft.copy(slug = it)) }, keyboard = KeyboardType.Uri)
                if (draft.kind == PostKind.REPLY) {
                    RowDivider()
                    PickerRow("RSVP", draft.field("rsvp"), listOf("" to "None", "yes" to "Going", "no" to "Not Going", "maybe" to "Maybe", "interested" to "Interested")) {
                        update(draft.withField("rsvp", it))
                    }
                }
            }
        }
        item {
            Group {
                SwitchRow("Set Date", draft.published.isNotEmpty()) { update(draft.withPublicationDate(it)) }
                if (draft.published.isNotEmpty()) { RowDivider(); DateRow("Date", draft.published) { update(draft.copy(published = it)) } }
                if (draft.editURL == null) { RowDivider(); SwitchRow("Post as Draft", draft.remoteDraft) { update(draft.copy(remoteDraft = it)) } }
                if (config.visibility.isNotEmpty()) {
                    RowDivider()
                    PickerRow("Visibility", draft.visibility, listOf("" to "Default") + config.visibility.map { it to it.capitalizedWords() }) { value ->
                        // Private posts are not sent to other networks.
                        update(draft.copy(visibility = value, syndication = if (value.isNotEmpty() && value != "public") emptyList() else draft.syndication))
                    }
                }
                if (config.channels.isNotEmpty()) {
                    RowDivider()
                    PickerRow("Channel", draft.channel, listOf("" to "Default") + config.channels.map { it to it }) { update(draft.copy(channel = it)) }
                }
            }
        }
        if (draft.kind.takesLocation) item {
            Group {
                FieldRow("Location", draft.location, "None", { update(draft.copy(location = it)) }, keyboard = KeyboardType.Uri)
                coordinate(draft.location)?.let { (lat, lon) ->
                    RowDivider()
                    ActionRow("Show on Map", value = "%.4f, %.4f".format(lat, lon)) {
                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("geo:$lat,$lon?q=$lat,$lon"))) }
                    }
                }
            }
        }
        if (draft.kind.takesPhotos) item {
            Group {
                FieldRow("Photo URL", draft.field("photo-url"), "None", { update(draft.withField("photo-url", it)) }, keyboard = KeyboardType.Uri)
                val media = config.mediaEndpoint
                val client = store.client
                if (media != null && client != null) {
                    RowDivider()
                    ActionRow("Use Latest Upload", enabled = !loadingLatest, color = MaterialTheme.colorScheme.primary,
                        trailing = if (loadingLatest) ({ CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) }) else null) {
                        scope.launch {
                            loadingLatest = true
                            try {
                                val item = client.latestMedia(media)
                                if (item == null) store.error = "No recent upload found."
                                else {
                                    var next = draft.withField("photo-url", item.url)
                                    item.published?.let { next = next.copy(published = it) }
                                    item.location?.let { next = next.copy(location = it) }
                                    update(next)
                                }
                            } catch (e: CancellationException) { throw e } catch (e: Exception) { store.error = e.message }
                            finally { loadingLatest = false }
                        }
                    }
                }
            }
        }
        item {
            Group {
                val formats = ContentFormat.supported(draft.kind)
                if (formats.size > 1) {
                    Box(Modifier.testTag("details.format")) {
                        PickerRow("Format", draft.format, formats.map { it to it.title }) { update(draft.withFormat(it)) }
                    }
                    RowDivider()
                }
                if (draft.kind == PostKind.ARTICLE && draft.isHTML) { SwitchRow("Edit as HTML", htmlSource, onChange = onHtmlSource); RowDivider() }
                Box(Modifier.testTag("details.request")) {
                    ActionRow("Request", trailing = { Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null) }, onClick = onRequest)
                }
            }
        }
        item { androidx.compose.foundation.layout.Spacer(Modifier.height(32.dp)) }
    }
}

/** The body Quill will send, for checking what a server receives. */
@Composable
private fun RequestView(draft: Draft, store: AppStore, onBack: () -> Unit) {
    val text = remember(draft) {
        runCatching { prettyJson(if (draft.editURL == null) Payload.create(draft, store.preferences) else Payload.update(draft, store.preferences)) }
            .getOrElse { it.message ?: "This post can’t be sent yet." }
    }
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 8.dp)) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") }
            Text("Request", style = MaterialTheme.typography.titleLarge)
        }
        SelectionContainer {
            Text(text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.fillMaxWidth().height(480.dp).verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()).padding(16.dp).testTag("request.body"))
        }
    }
}

/** The latitude and longitude in a geo: URI. */
fun coordinate(location: String): Pair<Double, Double>? {
    if (!location.startsWith("geo:")) return null
    val parts = location.removePrefix("geo:").substringBefore(';').split(',').mapNotNull { it.trim().toDoubleOrNull() }
    if (parts.size < 2 || parts[0] !in -90.0..90.0 || parts[1] !in -180.0..180.0) return null
    return parts[0] to parts[1]
}
