package com.quillnative.android

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import coil.compose.AsyncImage
import com.quillnative.core.Attachment
import com.quillnative.core.Draft
import com.quillnative.core.LinkContext
import com.quillnative.core.Payload
import com.quillnative.core.PostKind
import com.quillnative.core.Tags
import com.quillnative.core.WebUrl
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.cancellation.CancellationException

/** The share sheet: a post editor for whatever was shared, which saves a draft or posts straight away. */
class ShareActivity : ComponentActivity() {
    private val shared = mutableStateOf<Draft?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val store = store
        lifecycleScope.launch { shared.value = withContext(Dispatchers.IO) { read(intent, store) } }
        setContent {
            QuillTheme {
                val draft = shared.value
                ShareSheet(store, draft, onFinish = ::finish)
            }
        }
    }

    /** Turns the shared text, links and images into a draft: a link becomes a bookmark, images a photo post. */
    private suspend fun read(intent: Intent, store: AppStore): Draft {
        val texts = mutableListOf<String>()
        listOfNotNull(intent.getStringExtra(Intent.EXTRA_SUBJECT), intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString())
            .map { it.trim() }.filter { it.isNotEmpty() }.forEach { if (it !in texts) texts += it }
        val uris = buildList {
            if (intent.action == Intent.ACTION_SEND_MULTIPLE) addAll(parcelables(intent).filterIsInstance<Uri>())
            else parcelable(intent)?.let { if (it is Uri) add(it) }
        }
        val images = uris.mapNotNull { Media.photo(this, it, "shared") }
        // A link alone, or a link at the end of the text, as many apps share.
        var url: String? = null
        val index = texts.indexOfFirst { !it.any(Char::isWhitespace) && WebUrl.parseOrNull(it) != null }
        if (index >= 0) url = WebUrl.parse(texts.removeAt(index))
        else texts.lastOrNull()?.let { last ->
            val match = Regex("(https?://\\S+)\\s*$").find(last)
            if (match != null) {
                url = WebUrl.parseOrNull(match.groupValues[1])
                texts[texts.lastIndex] = last.removeRange(match.range).trim()
                texts.removeAll { it.isEmpty() }
            }
        }
        url?.let { link -> texts.removeAll { it == link } }
        val kind = if (url != null) PostKind.BOOKMARK else if (images.isEmpty()) PostKind.NOTE else PostKind.PHOTO
        var draft = Draft.create(kind, store.preferences, store.account?.me).copy(target = url.orEmpty())
        if (url != null && texts.isNotEmpty() && (texts.size > 1 || '\n' !in texts.first())) draft = draft.copy(title = texts.removeAt(0))
        return draft.copy(content = texts.distinct().joinToString("\n\n"), attachments = images)
    }

    @Suppress("DEPRECATION")
    private fun parcelable(intent: Intent): Parcelable? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Parcelable::class.java) else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun parcelables(intent: Intent): List<Parcelable> =
        (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Parcelable::class.java) else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)).orEmpty()
}

private val shareKinds = listOf(PostKind.BOOKMARK, PostKind.NOTE, PostKind.PHOTO, PostKind.REPLY, PostKind.LIKE, PostKind.REPOST)
private val PostKind.hasWords get() = this in setOf(PostKind.NOTE, PostKind.PHOTO, PostKind.REPLY, PostKind.BOOKMARK)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShareSheet(store: AppStore, initial: Draft?, onFinish: () -> Unit) {
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var draft by remember(initial) { mutableStateOf(initial) }
    var link by remember { mutableStateOf<LinkContext?>(null) }
    var known by remember { mutableStateOf(emptyList<String>()) }
    var tagInput by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf<String?>(null) }
    var done by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var kindMenu by remember { mutableStateOf(false) }
    var describing by remember { mutableStateOf<Attachment?>(null) }
    var kept by remember { mutableStateOf(false) }

    fun fail(message: String) { failure = message; haptics.performHapticFeedback(HapticFeedbackType.Reject) }
    fun close() {
        // A draft that was saved once keeps its latest edits.
        if (kept && !done) draft?.let { runCatching { store.save(it) } }
        scope.launch { sheet.hide(); onFinish() }
    }

    LaunchedEffect(Unit) {
        store.loadConfig()
        val local = withContext(Dispatchers.Default) { Tags.used(store.library.posts, store.drafts) }
        val site = runCatching { store.client?.categories() }.getOrNull().orEmpty()
        known = (local + site).distinctBy { it.lowercase() }
    }
    LaunchedEffect(draft?.target, draft?.kind) {
        val d = draft ?: return@LaunchedEffect
        val url = if (d.kind.hasTarget) WebUrl.parseOrNull(d.target) else null
        if (url == null) { link = null; return@LaunchedEffect }
        delay(600)
        val found = runCatching { LinkContext.fetch(url) }.getOrNull() ?: return@LaunchedEffect
        link = found
        draft = draft?.let { current ->
            var next = current
            if (next.title.isEmpty()) next = next.copy(title = found.title)
            if (next.field("summary").isEmpty() && found.description.isNotEmpty()) next = next.withField("summary", found.description)
            next
        }
    }
    val pickPhotos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(10)) { uris ->
        scope.launch {
            for (uri in uris) {
                val photo = Media.photo(context, uri)
                if (photo == null) fail("A photo couldn’t be read.") else draft = draft?.let { it.copy(attachments = it.attachments + photo) }
            }
        }
    }

    fun save() {
        val d = draft ?: return
        busy = "save"
        try { store.save(d); kept = true; done = true; haptics.performHapticFeedback(HapticFeedbackType.Confirm); close() }
        catch (e: Exception) { fail(e.message ?: "Couldn’t save this draft.") }
        finally { busy = null }
    }
    fun publish() {
        val d = draft ?: return
        if (store.account == null) { fail("Sign in to Quill to publish."); return }
        try { Payload.validate(d) } catch (e: Exception) { fail(e.message ?: "This post can’t be sent yet."); return }
        failure = null
        busy = "publish"
        scope.launch {
            try {
                store.publish(d)
                done = true
                haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                close()
            } catch (e: CancellationException) { throw e } catch (e: Exception) {
                kept = true
                store.drafts.firstOrNull { it.id == d.id }?.let { draft = it }
                fail("${e.message ?: "Couldn’t post."} It’s saved in Quill’s drafts.")
            } finally { busy = null }
        }
    }

    ModalBottomSheet(onDismissRequest = ::close, sheetState = sheet) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.92f).imePadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = ::close, modifier = Modifier.testTag("share.close")) { Icon(Icons.Outlined.Close, "Close") }
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                    val d = draft
                    if (d != null) {
                        Row(Modifier.clip(RoundedCornerShape(12.dp)).clickable { kindMenu = true }.padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(d.kind.title, style = MaterialTheme.typography.titleMedium)
                            Icon(Icons.Outlined.ArrowDropDown, "Post Type")
                        }
                        DropdownMenu(kindMenu, onDismissRequest = { kindMenu = false }) {
                            for (kind in shareKinds) DropdownMenuItem(text = { Text(kind.title) }, leadingIcon = { Icon(kind.icon, null) }, onClick = {
                                kindMenu = false
                                var next = d
                                // A link shared as a note goes into the note.
                                if (kind == PostKind.NOTE && d.target.isNotEmpty() && d.target !in d.content) next = next.copy(content = listOf(d.content, d.target).filter { it.isNotEmpty() }.joinToString("\n\n"))
                                draft = next.prepared(kind, store.preferences)
                                haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                            })
                        }
                    }
                }
                Spacer(Modifier.size(48.dp))
            }
            val d = draft
            if (d == null) {
                Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                return@Column
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).animateContentSize()) {
                failure?.let { message ->
                    Row(
                        Modifier.padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.errorContainer)
                            .clickable { failure = null }.padding(12.dp).testTag("share.error"),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) { Icon(Icons.Outlined.ErrorOutline, null); Text(message, style = MaterialTheme.typography.bodyMedium) }
                }
                if (store.account == null) Text("Sign in to Quill to publish.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp))
                if (d.kind.hasTarget) Group {
                    link?.image?.takeIf { d.kind != PostKind.LIKE && d.kind != PostKind.REPOST }?.let { image ->
                        AsyncImage(image, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxWidth().height(170.dp))
                    }
                    Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(d.kind.icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        PlainField(d.target, { draft = d.copy(target = it) }, "URL", Modifier.weight(1f).testTag("share.target"), keyboard = KeyboardType.Uri)
                    }
                    if (d.kind == PostKind.REPLY) {
                        RowDivider()
                        PickerRow("RSVP", d.field("rsvp"), listOf("" to "None", "yes" to "Going", "no" to "Not Going", "maybe" to "Maybe", "interested" to "Interested")) { draft = d.withField("rsvp", it) }
                    }
                }
                if (d.kind.hasWords) {
                    if (d.kind == PostKind.BOOKMARK) Group {
                        PlainField(d.title, { draft = d.copy(title = it) }, "Title", Modifier.fillMaxWidth(), singleLine = false,
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold))
                        RowDivider()
                        PlainField(d.field("summary"), { draft = d.withField("summary", it) }, "Description", Modifier.fillMaxWidth().testTag("share.summary"), singleLine = false)
                    }
                    Group {
                        PlainField(d.content, { draft = d.copy(content = it) }, if (d.kind == PostKind.BOOKMARK) "Note" else d.kind.prompt,
                            Modifier.fillMaxWidth().testTag("share.content"), singleLine = false, minLines = 3)
                    }
                    Group {
                        if (d.attachments.isNotEmpty()) {
                            Row(Modifier.horizontalScroll(rememberScrollState()).padding(12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                for (attachment in d.attachments) Box(Modifier.size(84.dp)) {
                                    PhotoView(Thumbnail.Local(attachment.data), Modifier.size(84.dp).clickable { describing = attachment }, corner = 12)
                                    Surface(onClick = { draft = d.copy(attachments = d.attachments.filter { it.id != attachment.id }) }, shape = CircleShape,
                                        color = MaterialTheme.colorScheme.inverseSurface.copy(alpha = 0.7f), modifier = Modifier.align(Alignment.TopEnd).padding(4.dp).size(22.dp)) {
                                        Icon(Icons.Outlined.Close, "Remove Photo", tint = MaterialTheme.colorScheme.inverseOnSurface, modifier = Modifier.padding(4.dp))
                                    }
                                }
                            }
                            RowDivider()
                        }
                        val preview = link?.image
                        if (preview != null && d.kind == PostKind.BOOKMARK) {
                            SwitchRow("Include Preview Image", d.field("photo-url") == preview) { on -> draft = d.withField("photo-url", if (on) preview else null) }
                            RowDivider()
                        }
                        ActionRow("Add Photos", color = MaterialTheme.colorScheme.primary, trailing = { Icon(Icons.Outlined.PhotoLibrary, null) }) {
                            pickPhotos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                        }
                    }
                }
                Group("Tags") {
                    if (d.tagList.isNotEmpty()) FlowRow(Modifier.padding(horizontal = 12.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        for (tag in d.tagList) InputChip(selected = false, onClick = { draft = d.copy(tags = Tags.remove(d.tags, tag)) }, label = { Text(tag) },
                            trailingIcon = { Icon(Icons.Outlined.Close, "Remove $tag", Modifier.size(16.dp)) })
                    }
                    PlainField(tagInput, { value ->
                        if (value.endsWith(",")) { draft = d.copy(tags = Tags.add(d.tags, value)); tagInput = "" } else tagInput = value
                    }, "Add Tags", Modifier.fillMaxWidth().testTag("share.tags"), words = false)
                    val suggestions = Tags.suggestions(tagInput, d.tags, link?.tags.orEmpty(), known)
                    AnimatedVisibility(suggestions.isNotEmpty()) {
                        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            for (tag in suggestions) SuggestionChip(onClick = { draft = d.copy(tags = Tags.add(d.tags, tag)); tagInput = "" }, label = { Text(tag) })
                        }
                    }
                }
                Group {
                    if (store.config.channels.isNotEmpty()) {
                        PickerRow("Channel", d.channel, listOf("" to "Default") + store.config.channels.map { it to it }) { draft = d.copy(channel = it) }; RowDivider()
                    }
                    if (store.config.visibility.isNotEmpty()) {
                        PickerRow("Visibility", d.visibility, listOf("" to "Default") + store.config.visibility.map { it to it.capitalizedWords() }) { value ->
                            draft = d.copy(visibility = value, syndication = if (value.isNotEmpty() && value != "public") emptyList() else d.syndication)
                        }; RowDivider()
                    }
                    FieldRow("Slug", d.slug, "Automatic", { draft = d.copy(slug = it) }, keyboard = KeyboardType.Uri); RowDivider()
                    SwitchRow("Set Date", d.published.isNotEmpty()) { draft = d.withPublicationDate(it) }
                    if (d.published.isNotEmpty()) { RowDivider(); DateRow("Date", d.published) { draft = d.copy(published = it) } }
                }
                if (store.config.targets.isNotEmpty() && (d.visibility.isEmpty() || d.visibility == "public")) Group("Syndication") {
                    store.config.targets.forEachIndexed { i, target ->
                        if (i > 0) RowDivider()
                        SwitchRow(target.name, target.uid in d.syndication) { on ->
                            draft = d.copy(syndication = d.syndication.filter { it != target.uid } + if (on) listOf(target.uid) else emptyList())
                        }
                    }
                }
                Spacer(Modifier.height(16.dp))
            }
            Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FilledTonalButton(onClick = ::save, enabled = busy == null && !done, modifier = Modifier.weight(1f).height(52.dp).testTag("share.save")) {
                    if (busy == "save") CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else Text("Save Draft")
                }
                Button(onClick = ::publish, enabled = busy == null && !done && store.account != null && !d.isBlank, modifier = Modifier.weight(1f).height(52.dp).testTag("share.publish")) {
                    when {
                        busy == "publish" -> CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary)
                        done -> Icon(Icons.Outlined.Check, "Posted")
                        else -> Text("Post", fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
    describing?.let { attachment ->
        TextDialog("Description", attachment.alt, label = "Describe this photo", onDismiss = { describing = null }) { alt ->
            draft = draft?.let { it.copy(attachments = it.attachments.map { a -> if (a.id == attachment.id) a.copy(alt = alt) else a }) }
            describing = null
        }
    }
}

