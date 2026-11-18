package com.quillnative.android

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.FormatBold
import androidx.compose.material.icons.outlined.FormatItalic
import androidx.compose.material.icons.outlined.FormatSize
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.LocationOff
import androidx.compose.material.icons.outlined.LocationOn
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.quillnative.core.Attachment
import com.quillnative.core.ContentFormat
import com.quillnative.core.Draft
import com.quillnative.core.Html
import com.quillnative.core.Iso8601
import com.quillnative.core.LinkContext
import com.quillnative.core.Payload
import com.quillnative.core.PostKind
import com.quillnative.core.SyndicationTarget
import com.quillnative.core.WebUrl
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComposerScreen(store: AppStore, initial: Draft, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val focusManager = LocalFocusManager.current
    var draft by remember { mutableStateOf(initial) }
    // A post just fetched for editing is only kept as a draft once it changes.
    var saved by remember { mutableStateOf(store.drafts.firstOrNull { it.id == initial.id } ?: if (initial.editURL != null) initial else null) }
    var sending by remember { mutableStateOf(false) }
    var finished by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var link by remember { mutableStateOf<LinkContext?>(null) }
    var showDetails by remember { mutableStateOf(false) }
    var recordingVoice by remember { mutableStateOf(false) }
    // Existing HTML opens as source, so formatting the editor can't show is kept.
    var htmlSource by remember { mutableStateOf(initial.editURL != null && initial.isHTML && saved == initial) }
    var describing by remember { mutableStateOf<Attachment?>(null) }
    var addingLink by remember { mutableStateOf(false) }
    var locating by remember { mutableStateOf(false) }
    var kindMenu by remember { mutableStateOf(false) }
    val rich = remember { RichTextController() }
    val content = remember { FocusRequester() }
    val target = remember { FocusRequester() }

    fun fail(message: String) { failure = message; haptics.performHapticFeedback(HapticFeedbackType.Reject) }
    fun update(next: Draft) { draft = next }
    fun persist() { if (!finished) saved = store.keep(draft, saved) }

    LaunchedEffect(Unit) {
        if (store.startsVoiceNote) { store.startsVoiceNote = false; recordingVoice = true }
        else runCatching { if (draft.kind.hasTarget && draft.target.isEmpty()) target.requestFocus() else if (draft.kind.hasText) content.requestFocus() }
    }
    LaunchedEffect(draft) { delay(700); persist() }
    val latest by rememberUpdatedState(::persist)
    DisposableEffect(Unit) { onDispose { latest() } }
    LaunchedEffect(draft.target, draft.kind) {
        val url = if (draft.kind.hasTarget) WebUrl.parseOrNull(draft.target) else null
        if (url == null) { link = null; return@LaunchedEffect }
        delay(500)
        val found = runCatching { LinkContext.fetch(url) }.getOrNull() ?: return@LaunchedEffect
        link = found
        if (draft.kind == PostKind.BOOKMARK && draft.title.isEmpty()) draft = draft.copy(title = found.title)
    }

    fun close() { persist(); onClose() }
    BackHandler(enabled = !sending) { close() }

    fun send() {
        focusManager.clearFocus()
        try { Payload.validate(draft) } catch (e: Exception) { fail(e.message ?: "This post can’t be sent yet."); return }
        failure = null
        sending = true
        scope.launch {
            try {
                store.publish(draft)
                finished = true
                haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                onClose()
            } catch (e: CancellationException) { throw e } catch (e: Exception) {
                store.drafts.firstOrNull { it.id == draft.id }?.let { draft = it; saved = it }
                fail(e.message ?: "Couldn’t send this post.")
            } finally { sending = false }
        }
    }

    // Photos, camera and location

    fun attach(attachment: Attachment?) {
        if (attachment == null) { fail("A photo couldn’t be read."); return }
        draft = draft.copy(attachments = draft.attachments + attachment)
        haptics.performHapticFeedback(HapticFeedbackType.ContextClick)
    }
    val pickPhotos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(10)) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            importing = true
            for (uri in uris) attach(Media.photo(context, uri))
            importing = false
        }
    }
    var cameraFile by remember { mutableStateOf<java.io.File?>(null) }
    val takePhoto = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { taken ->
        val file = cameraFile ?: return@rememberLauncherForActivityResult
        cameraFile = null
        if (!taken) { file.delete(); return@rememberLauncherForActivityResult }
        scope.launch {
            importing = true
            attach(Media.photo(context, android.net.Uri.fromFile(file), "camera"))
            file.delete()
            importing = false
        }
    }
    fun locate() {
        scope.launch {
            locating = true
            val found = Media.currentLocation(context)
            locating = false
            if (found == null) fail("Your location couldn’t be found.")
            else draft = draft.copy(location = "geo:${found.latitude},${found.longitude}")
        }
    }
    val askForLocation = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted.values.any { it }) locate() else fail("Allow location access in Settings to add where you are.")
    }
    fun toggleLocation() {
        if (draft.location.isNotEmpty()) { draft = draft.copy(location = ""); return }
        val allowed = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (allowed) locate() else askForLocation.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
    }

    /** Adds a transcript after what is already written, as a paragraph of its own. */
    fun insertVoiceNote(text: String, audio: Attachment?) {
        var next = draft
        if (text.isNotEmpty()) {
            next = if (next.isHTML) next.copy(content = next.content + "<p>${Html.escape(text)}</p>")
            else next.content.trim().let { current -> next.copy(content = if (current.isEmpty()) text else "$current\n\n$text") }
        }
        if (audio != null && next.editURL == null) next = next.copy(attachments = next.attachments + audio)
        draft = next
    }

    val formattable = draft.kind == PostKind.ARTICLE && (if (draft.isHTML) !htmlSource else draft.format == ContentFormat.MARKDOWN)
    val showsSyndication = draft.editURL == null && store.config.targets.isNotEmpty() && (draft.visibility.isEmpty() || draft.visibility == "public")
    val sendTitle = if (draft.editURL != null) "Update" else if (draft.remoteDraft) "Save Draft" else "Post"
    val kinds = if (draft.kind in store.preferences.visibleKinds) store.preferences.visibleKinds else PostKind.entries

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = ::close, enabled = !sending, modifier = Modifier.testTag("close")) { Icon(Icons.Outlined.Close, "Close") }
                },
                title = {
                    Box {
                        Row(
                            Modifier.clip(RoundedCornerShape(12.dp)).clickable(enabled = draft.editURL == null && !sending) { kindMenu = true }.padding(horizontal = 8.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(draft.kind.title)
                            if (draft.editURL == null) Icon(Icons.Outlined.ArrowDropDown, "Post Type")
                        }
                        DropdownMenu(expanded = kindMenu, onDismissRequest = { kindMenu = false }) {
                            for (kind in kinds) DropdownMenuItem(
                                text = { Text(kind.title) }, leadingIcon = { Icon(kind.icon, null) },
                                trailingIcon = if (kind == draft.kind) ({ Icon(Icons.Outlined.Check, null) }) else null,
                                onClick = {
                                    kindMenu = false
                                    if (kind != draft.kind) { draft = draft.prepared(kind, store.preferences); haptics.performHapticFeedback(HapticFeedbackType.SegmentTick) }
                                },
                            )
                        }
                    }
                },
                actions = {
                    Button(
                        onClick = ::send, enabled = !draft.isBlank && !sending && !importing,
                        modifier = Modifier.padding(end = 8.dp).testTag("publish"),
                    ) {
                        if (sending) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary)
                        else Text(sendTitle, fontWeight = FontWeight.SemiBold)
                    }
                },
            )
        },
        bottomBar = {
            ActionBar(
                draft, formattable, locating, enabled = !sending,
                onBold = rich::bold, onItalic = rich::italic, onHeading = rich::heading, onLink = { addingLink = true },
                onVoice = { focusManager.clearFocus(); recordingVoice = true },
                onPhotos = { pickPhotos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                onCamera = if (context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) ({
                    val (file, uri) = Media.cameraFile(context)
                    cameraFile = file
                    takePhoto.launch(uri)
                }) else null,
                onLocation = ::toggleLocation,
                onDetails = { showDetails = true },
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when {
                draft.kind.isStructured -> LazyColumn(Modifier.fillMaxSize()) {
                    failure?.let { message -> item { FailureBanner(message, Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) { failure = null } } }
                    structuredFields(draft, store.preferences.weightUnit, ::update)
                    if (showsSyndication) item {
                        Group("Syndication") {
                            store.config.targets.forEachIndexed { index, item ->
                                if (index > 0) RowDivider()
                                SwitchRow(item.name, item.uid in draft.syndication) { draft = draft.syndicating(item, it) }
                            }
                        }
                    }
                }
                draft.kind == PostKind.ARTICLE || draft.kind == PostKind.CODE -> Column(Modifier.fillMaxSize()) {
                    failure?.let { FailureBanner(it, Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) { failure = null } }
                    PlainField(draft.title, { draft = draft.copy(title = it) }, if (draft.kind == PostKind.CODE) "Filename" else "Title",
                        Modifier.fillMaxWidth().padding(horizontal = 4.dp).testTag("composer.title"), singleLine = false,
                        words = draft.kind != PostKind.CODE, style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold))
                    if (draft.kind == PostKind.CODE) {
                        PlainField(draft.field("language"), { draft = draft.withField("language", it) }, "Language", Modifier.fillMaxWidth().padding(horizontal = 4.dp), words = false,
                            style = MaterialTheme.typography.bodyMedium.copy(color = MaterialTheme.colorScheme.onSurfaceVariant))
                    }
                    Box(Modifier.weight(1f).fillMaxWidth()) {
                        when {
                            draft.kind == PostKind.ARTICLE && draft.isHTML && !htmlSource ->
                                RichEditor(draft.content, { draft = draft.copy(content = it) }, rich)
                            draft.kind == PostKind.ARTICLE && draft.format == ContentFormat.MARKDOWN ->
                                MarkdownEditor(draft.content, { draft = draft.copy(content = it) }, rich,
                                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()).focusRequester(content))
                            else -> PlainField(
                                draft.content, { draft = draft.copy(content = it) }, if (draft.kind == PostKind.CODE) "Code" else "Write",
                                Modifier.fillMaxSize().padding(horizontal = 4.dp).focusRequester(content).testTag("composer.content"),
                                words = false, singleLine = false,
                                style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                            )
                        }
                    }
                    PhotoStrip(draft, importing, Modifier.padding(horizontal = 20.dp, vertical = 8.dp), onDescribe = { describing = it }) { gone ->
                        draft = draft.copy(attachments = draft.attachments.filter { it.id != gone.id })
                    }
                }
                else -> Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 16.dp).widthIn(max = 700.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    AnimatedVisibility(failure != null) { failure?.let { FailureBanner(it) { failure = null } } }
                    if (draft.kind.hasTarget) TargetField(draft, link, target) { draft = draft.copy(target = it) }
                    if (draft.kind == PostKind.BOOKMARK) {
                        PlainField(draft.title, { draft = draft.copy(title = it) }, "Title", Modifier.fillMaxWidth(), singleLine = false,
                            style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold))
                    }
                    if (draft.kind.hasText) {
                        PlainField(draft.content, { draft = draft.copy(content = it) }, draft.kind.prompt,
                            Modifier.fillMaxWidth().heightIn(min = 120.dp).focusRequester(content).testTag("composer.content"), singleLine = false, minLines = 3)
                    }
                    PhotoStrip(draft, importing, onDescribe = { describing = it }) { gone -> draft = draft.copy(attachments = draft.attachments.filter { it.id != gone.id }) }
                    Chips(summary(draft)) { showDetails = true }
                    if (showsSyndication) SyndicationChips(store.config.targets, draft) { item, on ->
                        draft = draft.syndicating(item, on)
                        haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                    }
                }
            }
        }
    }

    if (showDetails) DetailsSheet(store, draft, htmlSource, { htmlSource = it }, ::update) { showDetails = false }
    if (recordingVoice) VoiceNoteSheet(attachRecording = draft.editURL == null, onDismiss = { recordingVoice = false }) { text, audio ->
        recordingVoice = false
        insertVoiceNote(text, audio)
    }
    describing?.let { attachment ->
        TextDialog("Description", attachment.alt, label = "Describe this photo", onDismiss = { describing = null }) { alt ->
            draft = draft.copy(attachments = draft.attachments.map { if (it.id == attachment.id) it.copy(alt = alt) else it })
            describing = null
        }
    }
    if (addingLink) UrlDialog("Link", "Add", onDismiss = { addingLink = false }) { value ->
        addingLink = false
        runCatching { WebUrl.site(value) }.getOrNull()?.let(rich::link)
    }
}

private fun Draft.syndicating(target: SyndicationTarget, on: Boolean): Draft =
    copy(syndication = syndication.filter { it != target.uid } + if (on) listOf(target.uid) else emptyList())

private data class Chip(val icon: ImageVector, val text: String)

/** What has been set in Details, at a glance. */
private fun summary(draft: Draft): List<Chip> = buildList {
    if (draft.location.isNotEmpty()) add(Chip(Icons.Outlined.LocationOn, if (draft.location.startsWith("geo:")) "Current Location" else draft.location))
    if (draft.tags.isNotEmpty()) add(Chip(Icons.Outlined.Tag, draft.tags))
    Iso8601.parse(draft.published)?.let { add(Chip(Icons.Outlined.CalendarMonth, mediumDateTime(it))) }
    if (draft.remoteDraft) add(Chip(Icons.Outlined.Description, "Draft"))
    draft.field("rsvp").takeIf { it.isNotEmpty() }?.let { add(Chip(Icons.Outlined.CheckCircle, "RSVP ${it.capitalizedWords()}")) }
    if (draft.visibility.isNotEmpty() && draft.visibility != "public") add(Chip(Icons.Outlined.VisibilityOff, draft.visibility.capitalizedWords()))
}

@Composable
private fun FailureBanner(message: String, modifier: Modifier = Modifier, onDismiss: () -> Unit) {
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.errorContainer).clickable(onClick = onDismiss).padding(12.dp).testTag("composer.error"),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Outlined.ErrorOutline, null, tint = MaterialTheme.colorScheme.onErrorContainer)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onErrorContainer)
    }
}

@Composable
private fun TargetField(draft: Draft, link: LinkContext?, focus: FocusRequester, onChange: (String) -> Unit) {
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh).heightIn(min = 52.dp).padding(start = 14.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(draft.kind.icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            PlainField(draft.target, onChange, "URL", Modifier.weight(1f).focusRequester(focus).testTag("composer.target"), keyboard = KeyboardType.Uri)
            AnimatedVisibility(draft.target.isEmpty(), enter = fadeIn() + scaleIn(), exit = fadeOut() + scaleOut()) {
                IconButton(onClick = {
                    scope.launch {
                        val text = clipboard.getClipEntry()?.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
                        if (!text.isNullOrBlank()) onChange(text.trim())
                    }
                }) { Icon(Icons.Outlined.ContentPaste, "Paste") }
            }
        }
        AnimatedVisibility(link != null, enter = fadeIn() + scaleIn(initialScale = 0.97f), exit = fadeOut()) {
            link?.let {
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.surfaceContainer).padding(12.dp)) {
                    Text(it.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    if (it.description.isNotEmpty()) Text(it.description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun PhotoStrip(draft: Draft, importing: Boolean, modifier: Modifier = Modifier, onDescribe: (Attachment) -> Unit, onRemove: (Attachment) -> Unit) {
    if (draft.attachments.isEmpty() && !importing) return
    Row(modifier.horizontalScroll(rememberScrollState()).animateContentSize(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        for (attachment in draft.attachments) {
            if (attachment.isAudio) AudioTile { onRemove(attachment) }
            else PhotoTile(attachment, { onDescribe(attachment) }) { onRemove(attachment) }
        }
        if (importing) Box(Modifier.size(96.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
    }
}

@Composable
private fun PhotoTile(attachment: Attachment, onDescribe: () -> Unit, onRemove: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box(Modifier.size(96.dp)) {
        PhotoView(Thumbnail.Local(attachment.data), Modifier.fillMaxSize().clickable { menu = true }, corner = 14)
        if (attachment.alt.isNotEmpty()) {
            Text("ALT", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.inverseOnSurface,
                modifier = Modifier.align(Alignment.BottomStart).padding(6.dp).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.inverseSurface.copy(alpha = 0.7f)).padding(horizontal = 4.dp))
        }
        Surface(onClick = onRemove, shape = CircleShape, color = MaterialTheme.colorScheme.inverseSurface.copy(alpha = 0.7f), modifier = Modifier.align(Alignment.TopEnd).padding(4.dp).size(24.dp)) {
            Icon(Icons.Outlined.Close, "Remove Photo", tint = MaterialTheme.colorScheme.inverseOnSurface, modifier = Modifier.padding(4.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Description") }, onClick = { menu = false; onDescribe() })
            DropdownMenuItem(text = { Text("Remove", color = MaterialTheme.colorScheme.error) }, onClick = { menu = false; onRemove() })
        }
    }
}

@Composable
private fun AudioTile(onRemove: () -> Unit) {
    Box(Modifier.size(96.dp).clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.secondaryContainer), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Outlined.GraphicEq, null, tint = MaterialTheme.colorScheme.onSecondaryContainer)
            Text("Recording", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSecondaryContainer)
        }
        Surface(onClick = onRemove, shape = CircleShape, color = MaterialTheme.colorScheme.inverseSurface.copy(alpha = 0.7f), modifier = Modifier.align(Alignment.TopEnd).padding(4.dp).size(24.dp)) {
            Icon(Icons.Outlined.Close, "Remove Recording", tint = MaterialTheme.colorScheme.inverseOnSurface, modifier = Modifier.padding(4.dp))
        }
    }
}

@Composable
private fun Chips(items: List<Chip>, onClick: () -> Unit) {
    if (items.isEmpty()) return
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (item in items) {
            Row(
                Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.surfaceContainerHigh).clickable(onClick = onClick).padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(item.icon, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(item.text, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
        }
    }
}

@Composable
private fun SyndicationChips(targets: List<SyndicationTarget>, draft: Draft, onToggle: (SyndicationTarget, Boolean) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (target in targets) {
            val on = target.uid in draft.syndication
            FilterChip(
                selected = on, onClick = { onToggle(target, !on) }, label = { Text(target.name) },
                leadingIcon = { Icon(if (on) Icons.Outlined.Check else Icons.Outlined.Add, null, Modifier.size(FilterChipDefaults.IconSize)) },
            )
        }
    }
}

@Composable
private fun ActionBar(
    draft: Draft, formattable: Boolean, locating: Boolean, enabled: Boolean,
    onBold: () -> Unit, onItalic: () -> Unit, onHeading: () -> Unit, onLink: () -> Unit, onVoice: () -> Unit,
    onPhotos: () -> Unit, onCamera: (() -> Unit)?, onLocation: () -> Unit, onDetails: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh, tonalElevation = 3.dp, shadowElevation = 2.dp,
        modifier = Modifier.navigationBarsPadding().imePadding().padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Row(Modifier.padding(horizontal = 4.dp).animateContentSize()) {
            @Composable fun bar(label: String, icon: ImageVector, tag: String? = null, action: () -> Unit) =
                IconButton(onClick = action, enabled = enabled, modifier = if (tag != null) Modifier.testTag(tag) else Modifier) { Icon(icon, label) }
            if (formattable) {
                bar("Bold", Icons.Outlined.FormatBold, action = onBold)
                bar("Italic", Icons.Outlined.FormatItalic, action = onItalic)
                bar("Heading", Icons.Outlined.FormatSize, action = onHeading)
                bar("Link", Icons.Outlined.Link, action = onLink)
            }
            if (draft.kind.takesVoice) bar("Voice Note", Icons.Outlined.Mic, "voice", onVoice)
            if (draft.kind.takesPhotos && draft.editURL == null) {
                bar("Photo Library", Icons.Outlined.PhotoLibrary, action = onPhotos)
                onCamera?.let { bar("Take Photo", Icons.Outlined.CameraAlt, action = it) }
            }
            if (draft.kind.takesLocation && draft.editURL == null) {
                IconButton(onClick = onLocation, enabled = enabled && !locating) {
                    if (locating) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    else Icon(if (draft.location.isEmpty()) Icons.Outlined.LocationOn else Icons.Outlined.LocationOff,
                        if (draft.location.isEmpty()) "Add Location" else "Remove Location",
                        tint = if (draft.location.isEmpty()) androidx.compose.ui.graphics.Color.Unspecified else MaterialTheme.colorScheme.primary)
                }
            }
            bar("Details", Icons.Outlined.MoreHoriz, "details", onDetails)
        }
    }
}

