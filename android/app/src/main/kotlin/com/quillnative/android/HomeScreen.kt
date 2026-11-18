package com.quillnative.android

import android.content.ClipData
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.quillnative.core.Draft
import com.quillnative.core.Post
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(store: AppStore, openSettings: () -> Unit) {
    var search by rememberSaveable { mutableStateOf("") }
    var searching by rememberSaveable { mutableStateOf(false) }
    var askingForUrl by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<Post?>(null) }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    val scroll = TopAppBarDefaults.enterAlwaysScrollBehavior()

    val drafts = store.drafts.filter { search.isEmpty() || it.displayTitle.contains(search, ignoreCase = true) }
    val hidden = store.preferences.hiddenKinds.toSet()
    val posts = store.library.search(search).filter { it.kind !in hidden }

    fun openOnWeb(post: Post) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(post.url)))
    /** Editable posts open in the composer. Others open on the site. */
    fun open(post: Post) = if (post.kind.isEditable) store.edit(post) else openOnWeb(post)

    LaunchedEffect(store.sent) { if (store.sent > 0) haptics.performHapticFeedback(HapticFeedbackType.Confirm) }

    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            Column {
                TopAppBar(
                    title = {
                        if (searching) {
                            TextField(
                                value = search, onValueChange = { search = it }, singleLine = true, placeholder = { Text("Search") },
                                colors = TextFieldDefaults.colors(focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent),
                                modifier = Modifier.fillMaxWidth(),
                            )
                        } else Column {
                            Text(store.account?.host ?: "Posts", maxLines = 1, overflow = TextOverflow.Ellipsis)
                            store.syncProgress?.let { Text(syncText(it), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                    },
                    actions = {
                        if (searching) IconButton(onClick = { searching = false; search = "" }) { Icon(Icons.Outlined.Close, "Close Search") }
                        else IconButton(onClick = { searching = true }) { Icon(Icons.Outlined.Search, "Search") }
                        IconButton(onClick = openSettings, modifier = Modifier.testTag("settings")) { Icon(Icons.Outlined.Settings, "Settings") }
                    },
                    scrollBehavior = scroll,
                )
                store.syncProgress?.let { progress ->
                    if (progress.fraction != null) LinearProgressIndicator(progress = { progress.fraction.toFloat() }, modifier = Modifier.fillMaxWidth())
                    else if (progress.count > 0) LinearProgressIndicator(Modifier.fillMaxWidth())
                }
            }
        },
        floatingActionButton = { ComposeButton(store, onEditPost = { askingForUrl = true }) },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { scope.launch { refreshing = true; store.reloadDrafts(); store.refresh(asking = true); refreshing = false } },
            modifier = Modifier.padding(padding).fillMaxSize(),
        ) {
            LazyColumn(Modifier.fillMaxSize()) {
                if (drafts.isNotEmpty()) {
                    item(key = "drafts-header") { SectionHeader("Drafts") }
                    items(drafts, key = { "draft-" + it.id }) { draft ->
                        DraftRow(draft, onOpen = { store.open(draft) }, onDelete = { store.remove(draft) }, modifier = Modifier.animateItem())
                    }
                }
                if (posts.isNotEmpty()) {
                    item(key = "posts-header") { SectionHeader("Posts") }
                    items(posts, key = { "post-" + it.id }) { post ->
                        LaunchedEffect(post.id) { store.describe(post) }
                        PostRow(
                            post, loading = store.opening == post.id, modifier = Modifier.animateItem(),
                            onOpen = { open(post) }, onEdit = { store.edit(post) }, onWeb = { openOnWeb(post) }, onDelete = { deleting = post },
                        )
                    }
                }
                item { Spacer(Modifier.height(96.dp)) }
            }
            EmptyState(store, drafts.isEmpty() && posts.isEmpty(), search)
        }
    }

    if (store.askingToSync) {
        AlertDialog(
            onDismissRequest = { store.askingToSync = false },
            title = { Text("Sync Your Posts?") },
            text = { Text("Keep a copy on this device to browse, search and edit your posts.") },
            confirmButton = { TextButton(onClick = { store.askingToSync = false; store.setSync(true) }) { Text("Sync") } },
            dismissButton = { TextButton(onClick = { store.askingToSync = false; if (store.syncEnabled == null) store.setSync(false) }) { Text("Not Now") } },
        )
    }
    deleting?.let { post ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete Post") },
            text = { Text(post.displayTitle, maxLines = 4, overflow = TextOverflow.Ellipsis) },
            confirmButton = { TextButton(onClick = { deleting = null; store.delete(post) }) { Text("Delete", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
        )
    }
    if (askingForUrl) UrlDialog("Edit Post", "Edit", onDismiss = { askingForUrl = false }) { askingForUrl = false; store.edit(it) }
}

private fun syncText(progress: AppStore.SyncProgress): String = when {
    progress.fraction != null -> "Syncing ${(progress.fraction * 100).toInt()}%"
    progress.count == 0 -> "Syncing"
    else -> "Syncing ${progress.count} Posts"
}

@Composable
private fun EmptyState(store: AppStore, empty: Boolean, search: String) {
    if (!empty) return
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        when {
            store.drafts.isEmpty() && store.library.posts.isEmpty() && store.syncing -> CircularProgressIndicator()
            store.drafts.isEmpty() && store.library.posts.isEmpty() -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Outlined.EditNote, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("No Posts", style = MaterialTheme.typography.titleLarge)
                if (store.syncEnabled != true) {
                    Text("Sync to browse, search and edit your posts here.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Button(onClick = { store.setSync(true) }) { Text("Sync Posts") }
                }
            }
            else -> Text("No results for “$search”", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
fun SectionHeader(title: String) {
    Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp))
}

/** Tap for the first post type. Touch and hold for every other kind of post. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ComposeButton(store: AppStore, onEditPost: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    Box {
        FloatingActionButton(onClick = {}, modifier = Modifier.testTag("compose")) {
            Box(
                Modifier.size(56.dp).combinedClickable(
                    onClick = { store.compose(store.preferences.visibleKinds.firstOrNull() ?: com.quillnative.core.PostKind.NOTE) },
                    onLongClick = { haptics.performHapticFeedback(HapticFeedbackType.LongPress); menu = true },
                    onClickLabel = "New Post", onLongClickLabel = "Choose Post Type",
                ),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Outlined.Edit, "New Post") }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            for (kind in store.preferences.visibleKinds) {
                DropdownMenuItem(text = { Text(kind.title) }, leadingIcon = { Icon(kind.icon, null) }, onClick = { menu = false; store.compose(kind) })
            }
            HorizontalDivider()
            DropdownMenuItem(text = { Text("Voice Note") }, leadingIcon = { Icon(Icons.Outlined.Mic, null) }, onClick = { menu = false; store.composeVoiceNote() })
            DropdownMenuItem(text = { Text("Edit Post…") }, leadingIcon = { Icon(Icons.Outlined.Edit, null) }, onClick = { menu = false; onEditPost() })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DraftRow(draft: Draft, onOpen: () -> Unit, onDelete: () -> Unit, modifier: Modifier = Modifier) {
    val dismiss = rememberSwipeToDismissBoxState(confirmValueChange = { if (it == SwipeToDismissBoxValue.EndToStart) { onDelete(); true } else false })
    var menu by remember { mutableStateOf(false) }
    SwipeToDismissBox(dismiss, enableDismissFromStartToEnd = false, backgroundContent = { DeleteBackground() }, modifier = modifier) {
        Box {
            Row(draft.kind.icon, draft.displayTitle, relative(draft.modified), null,
                photo = draft.attachments.firstOrNull { !it.isAudio }?.let { Thumbnail.Local(it.data) }, loading = false,
                onClick = onOpen, onLongClick = { menu = true })
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Delete") }, leadingIcon = { Icon(Icons.Outlined.Delete, null) }, onClick = { menu = false; onDelete() })
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PostRow(post: Post, loading: Boolean, onOpen: () -> Unit, onEdit: () -> Unit, onWeb: () -> Unit, onDelete: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    val dismiss = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        when (value) {
            SwipeToDismissBoxValue.EndToStart -> onDelete()
            SwipeToDismissBoxValue.StartToEnd -> if (post.kind.isEditable) onEdit() else onWeb()
            else -> {}
        }
        false
    })
    val status = if (post.isDraft) "Draft" else post.citeName?.takeIf { it != post.displayTitle && !post.displayTitle.startsWith(it) }
    SwipeToDismissBox(dismiss, backgroundContent = {
        if (dismiss.dismissDirection == SwipeToDismissBoxValue.StartToEnd) EditBackground(post.kind.isEditable) else DeleteBackground()
    }, modifier = modifier) {
        Box {
            Row(post.kind.icon, post.displayTitle, post.published?.let(::relative), status,
                photo = post.photo?.let { Thumbnail.Remote(it) }, loading = loading, onClick = onOpen, onLongClick = { menu = true })
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (post.kind.isEditable) DropdownMenuItem(text = { Text("Edit") }, leadingIcon = { Icon(Icons.Outlined.Edit, null) }, onClick = { menu = false; onEdit() })
                DropdownMenuItem(text = { Text("See on Web") }, leadingIcon = { Icon(Icons.Outlined.Public, null) }, onClick = { menu = false; onWeb() })
                DropdownMenuItem(text = { Text("Share") }, leadingIcon = { Icon(Icons.Outlined.Share, null) }, onClick = {
                    menu = false
                    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, post.url), null))
                })
                DropdownMenuItem(text = { Text("Copy Link") }, leadingIcon = { Icon(Icons.Outlined.ContentCopy, null) }, onClick = {
                    menu = false
                    scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Link", post.url))) }
                })
                HorizontalDivider()
                DropdownMenuItem(text = { Text("Delete", color = MaterialTheme.colorScheme.error) }, leadingIcon = { Icon(Icons.Outlined.Delete, null, tint = MaterialTheme.colorScheme.error) },
                    onClick = { menu = false; onDelete() })
            }
        }
    }
}

@Composable
private fun DeleteBackground() {
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.errorContainer).padding(horizontal = 24.dp), contentAlignment = Alignment.CenterEnd) {
        Icon(Icons.Outlined.Delete, "Delete", tint = MaterialTheme.colorScheme.onErrorContainer)
    }
}

@Composable
private fun EditBackground(editable: Boolean) {
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.primaryContainer).padding(horizontal = 24.dp), contentAlignment = Alignment.CenterStart) {
        Icon(if (editable) Icons.Outlined.Edit else Icons.Outlined.Public, if (editable) "Edit" else "See on Web", tint = MaterialTheme.colorScheme.onPrimaryContainer)
    }
}

sealed interface Thumbnail {
    class Local(val data: ByteArray) : Thumbnail
    class Remote(val url: String) : Thumbnail
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Row(
    icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, date: String?, status: String?,
    photo: Thumbnail?, loading: Boolean, onClick: () -> Unit, onLongClick: () -> Unit,
) {
    ListItem(
        modifier = Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick),
        leadingContent = { Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.width(28.dp)) },
        headlineContent = { Text(title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = listOfNotNull(status, date).takeIf { it.isNotEmpty() }?.let { parts -> { Text(parts.joinToString(" · "), maxLines = 1) } },
        trailingContent = when {
            loading -> { { CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp) } }
            photo != null -> { { PhotoView(photo, Modifier.size(48.dp)) } }
            else -> null
        },
    )
}

@Composable
fun PhotoView(photo: Thumbnail, modifier: Modifier = Modifier, corner: Int = 8) {
    val shape = RoundedCornerShape(corner.dp)
    Box(modifier.clip(shape).background(MaterialTheme.colorScheme.surfaceContainerHighest)) {
        when (photo) {
            is Thumbnail.Remote -> AsyncImage(model = photo.url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            is Thumbnail.Local -> {
                val bitmap by produceState<android.graphics.Bitmap?>(null, photo) { value = withContext(Dispatchers.Default) { decodeThumbnail(photo.data, 288) } }
                bitmap?.let { Image(it.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
            }
        }
    }
}

/** A bitmap no larger than about `size` pixels on its short edge, for thumbnails. */
fun decodeThumbnail(data: ByteArray, size: Int): android.graphics.Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
    var sample = 1
    while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= size) sample *= 2
    return BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample })
}

@Composable
fun UrlDialog(title: String, action: String, initial: String = "", onDismiss: () -> Unit, onDone: (String) -> Unit) {
    var value by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(value, { value = it }, singleLine = true, label = { Text("URL") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
        },
        confirmButton = { TextButton(onClick = { onDone(value) }, enabled = value.isNotBlank()) { Text(action) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

