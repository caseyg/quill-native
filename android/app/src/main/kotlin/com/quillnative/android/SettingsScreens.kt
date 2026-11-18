package com.quillnative.android

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.quillnative.core.ContentFormat
import com.quillnative.core.GitHubDeclined
import com.quillnative.core.GitHubDeviceCode
import com.quillnative.core.GitHubRepository
import com.quillnative.core.PostKind
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

val Warning = Color(0xFFE08600)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SubScreen(title: String, onBack: () -> Unit, actions: @Composable () -> Unit = {}, content: @Composable (Modifier) -> Unit) {
    Scaffold(topBar = {
        TopAppBar(
            title = { Text(title) },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
            actions = { actions() },
        )
    }) { padding -> content(Modifier.padding(padding).fillMaxSize()) }
}

@Composable
private fun Chevron() = Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(store: AppStore, push: (Screen) -> Unit, pop: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var confirmingSignOut by remember { mutableStateOf(false) }
    var confirmingStopSync by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    val preferences = store.preferences
    fun open(url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))

    SubScreen("Settings", pop) { modifier ->
        PullToRefreshBox(refreshing, onRefresh = { scope.launch { refreshing = true; store.refresh(); refreshing = false } }, modifier = modifier) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                store.account?.let { account -> Group { InfoRow("Site", account.host) } }
                Group {
                    ActionRow("Post Types", trailing = { Chevron() }) { push(Screen.POST_TYPES) }
                    RowDivider()
                    Column(Modifier.testTag("settings.format")) {
                        PickerRow("Format", preferences.format, ContentFormat.entries.map { it to it.title }) { value -> store.updatePreferences { it.copy(format = value) } }
                    }
                    RowDivider()
                    PickerRow("Weight Unit", preferences.weightUnit, listOf("lb" to "Pounds", "kg" to "Kilograms", "st" to "Stone")) { value -> store.updatePreferences { it.copy(weightUnit = value) } }
                    RowDivider()
                    ActionRow("Advanced", trailing = { Chevron() }) { push(Screen.ADVANCED) }
                }
                Group(footer = if (store.syncEnabled == true) syncSummary(store) else null) {
                    Column(Modifier.testTag("settings.sync")) {
                        SwitchRow("Sync Posts", store.syncEnabled == true) { on -> if (on) store.setSync(true) else confirmingStopSync = true }
                    }
                    if (store.syncEnabled == true) {
                        RowDivider()
                        ActionRow("Sync Everything Again", color = MaterialTheme.colorScheme.primary, enabled = !store.syncing) { store.syncEverything() }
                    }
                }
                val repository = store.github.connection?.repository
                Group(footer = if (repository != null && !repository.isPrivate) "Public repository. Anyone can read these drafts." else null) {
                    Column(Modifier.testTag("settings.github")) {
                        ActionRow("Drafts on GitHub", trailing = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(repository?.fullName ?: "Off", color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Chevron()
                            }
                        }) { push(Screen.GITHUB) }
                    }
                }
                Group(footer = "Version ${BuildConfig.VERSION_NAME}") {
                    ActionRow("Source Code", color = MaterialTheme.colorScheme.primary) { open("https://github.com/caseyg/quill-native") }
                    RowDivider()
                    ActionRow("Based on Quill", color = MaterialTheme.colorScheme.primary) { open("https://github.com/aaronpk/Quill") }
                }
                Group {
                    Column(Modifier.testTag("signout")) {
                        ActionRow("Sign Out", color = MaterialTheme.colorScheme.error) { confirmingSignOut = true }
                    }
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }

    if (confirmingSignOut) AlertDialog(
        onDismissRequest = { confirmingSignOut = false },
        title = { Text("Sign Out") },
        confirmButton = { TextButton(onClick = { confirmingSignOut = false; pop(); store.signOut() }) { Text("Sign Out", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmingSignOut = false }) { Text("Cancel") } },
    )
    if (confirmingStopSync) AlertDialog(
        onDismissRequest = { confirmingStopSync = false },
        title = { Text("Stop Syncing") },
        text = { Text("Posts on your site aren’t affected.") },
        confirmButton = { TextButton(onClick = { confirmingStopSync = false; store.setSync(false) }) { Text("Delete Posts from Phone", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmingStopSync = false }) { Text("Cancel") } },
    )
}

private fun syncSummary(store: AppStore): String {
    val count = "%,d posts on this phone".format(store.library.posts.size)
    if (store.syncing) return "$count · Syncing"
    val synced = store.library.synced ?: return count
    return "$count · Updated ${relative(synced)}"
}

/** Post types to offer when posting and to show in the list. */
@Composable
fun PostTypesScreen(store: AppStore, pop: () -> Unit) {
    SubScreen("Post Types", pop) { modifier ->
        LazyColumn(modifier) {
            items(PostKind.entries) { kind ->
                val shown = kind !in store.preferences.hiddenKinds
                // Keep at least one type, so there is always something to post.
                val locked = store.preferences.visibleKinds == listOf(kind)
                ListItem(
                    leadingContent = { Icon(kind.icon, null, tint = MaterialTheme.colorScheme.primary) },
                    headlineContent = { Text(kind.title) },
                    trailingContent = {
                        Switch(shown, enabled = !locked, onCheckedChange = { on ->
                            store.updatePreferences { p -> p.copy(hiddenKinds = p.hiddenKinds.filter { it != kind } + if (on) emptyList() else listOf(kind)) }
                        })
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
            }
        }
    }
}

/** Settings most people never change: server details, per-type formats and protocol switches. */
@Composable
fun AdvancedScreen(store: AppStore, pop: () -> Unit) {
    val preferences = store.preferences
    SubScreen("Advanced", pop) { modifier ->
        Column(modifier.verticalScroll(rememberScrollState())) {
            store.account?.let { account ->
                Group("Server") {
                    InfoRow("Micropub", account.micropub)
                    store.config.mediaEndpoint?.let { RowDivider(); InfoRow("Media", it) }
                    if (account.scope.isNotEmpty()) { RowDivider(); InfoRow("Permissions", account.scope) }
                    if (store.config.targets.isNotEmpty()) { RowDivider(); InfoRow("Syndication", store.config.targets.joinToString(", ") { it.name }) }
                }
            }
            Group("Format by Post Type") {
                PostKind.entries.filter { ContentFormat.supported(it).size > 1 }.forEachIndexed { index, kind ->
                    if (index > 0) RowDivider()
                    PickerRow(kind.title, preferences.formatOverrides[kind], listOf<Pair<ContentFormat?, String>>(null to "Default") + ContentFormat.supported(kind).map { it to it.title }) { value ->
                        store.updatePreferences { p -> p.copy(formatOverrides = if (value == null) p.formatOverrides - kind else p.formatOverrides + (kind to value)) }
                    }
                }
            }
            Group("Compatibility") {
                SwitchRow("HTML Content Object", preferences.htmlContent) { on -> store.updatePreferences { it.copy(htmlContent = on) } }
                RowDivider()
                SwitchRow("Form Encoding", preferences.formEncoded) { on -> store.updatePreferences { it.copy(formEncoded = on) } }
                RowDivider()
                FieldRow("Slug Field", preferences.slugField, "mp-slug", { value -> store.updatePreferences { it.copy(slugField = value) } }, keyboard = KeyboardType.Ascii)
                RowDivider()
                PickerRow("Syndication Field", preferences.syndicationField, listOf("mp-syndicate-to" to "mp-syndicate-to", "syndicate-to" to "syndicate-to")) { value ->
                    store.updatePreferences { it.copy(syndicationField = value) }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

/** Signing in to GitHub, picking a repository, and the state of copying drafts there. */
@Composable
fun GitHubScreen(store: AppStore, push: (Screen) -> Unit, pop: () -> Unit) {
    val github = store.github
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf<GitHubDeviceCode?>(null) }
    var enteringToken by remember { mutableStateOf(false) }
    var confirmingSignOut by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var starting by remember { mutableStateOf(false) }
    var folder by remember { mutableStateOf(github.connection?.folder ?: "drafts") }
    // Applied when typing pauses, so each keystroke doesn't move the drafts.
    LaunchedEffect(folder) { delay(1500); if (github.connection != null && folder != github.connection?.folder) github.setFolder(folder) }

    SubScreen("Drafts on GitHub", pop) { modifier ->
        Column(modifier.verticalScroll(rememberScrollState())) {
            val connection = github.connection
            if (connection == null) {
                Group(footer = listOfNotNull("Saving a draft writes it to a repository you choose, as Markdown. Posting still goes to your site.", failure).joinToString("\n\n")) {
                    if (GitHubBackup.clientId != null) {
                        Column(Modifier.testTag("github.signin")) {
                            ActionRow("Sign In with GitHub", color = MaterialTheme.colorScheme.primary, enabled = !starting,
                                trailing = if (starting) ({ CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) }) else null) {
                                scope.launch {
                                    starting = true; failure = null
                                    try { code = github.startSignIn() } catch (e: CancellationException) { throw e } catch (e: Exception) { failure = e.message }
                                    finally { starting = false }
                                }
                            }
                        }
                        RowDivider()
                    }
                    Column(Modifier.testTag("github.token")) {
                        ActionRow("Use a Token", color = MaterialTheme.colorScheme.primary) { enteringToken = true }
                    }
                }
            } else {
                val repository = connection.repository
                Group(footer = if (repository != null && !repository.isPrivate) "This repository is public. Anyone can read these drafts on GitHub." else null) {
                    InfoRow("Account", connection.login)
                    RowDivider()
                    if (repository != null) {
                        Column(Modifier.testTag("github.repository")) {
                            ActionRow("Repository", trailing = {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Icon(if (repository.isPrivate) Icons.Outlined.Lock else Icons.Outlined.Public, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Text(repository.fullName, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Chevron()
                                }
                            }) { push(Screen.REPOSITORIES) }
                        }
                        RowDivider()
                        FieldRow("Folder", folder, "Top Level", { folder = it }, keyboard = KeyboardType.Uri)
                    } else {
                        Column(Modifier.testTag("github.choose")) {
                            ActionRow("Choose Repository", trailing = { Chevron() }) { push(Screen.REPOSITORIES) }
                        }
                    }
                }
                if (repository != null) {
                    val status = when {
                        github.syncing -> "Syncing"
                        github.problem != null -> github.problem
                        github.synced != null -> "Updated ${relative(github.synced!!)}"
                        else -> null
                    }
                    Group(footer = status) {
                        ActionRow("Sync Now", color = MaterialTheme.colorScheme.primary, enabled = !github.syncing) { scope.launch { github.sync() } }
                        RowDivider()
                        ActionRow("Open on GitHub", color = MaterialTheme.colorScheme.primary) {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/${repository.fullName}")))
                        }
                    }
                }
                Group { ActionRow("Sign Out of GitHub", color = MaterialTheme.colorScheme.error) { confirmingSignOut = true } }
            }
        }
    }

    code?.let { DeviceCodeDialog(store, it) { code = null } }
    if (enteringToken) TokenDialog(store) { enteringToken = false }
    if (confirmingSignOut) AlertDialog(
        onDismissRequest = { confirmingSignOut = false },
        title = { Text("Sign Out of GitHub") },
        text = { Text("Drafts stop syncing. Copies already on GitHub stay there.") },
        confirmButton = { TextButton(onClick = { confirmingSignOut = false; github.disconnect() }) { Text("Sign Out", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmingSignOut = false }) { Text("Cancel") } },
    )
}

/** Shows the code to enter on github.com and waits for approval. */
@Composable
private fun DeviceCodeDialog(store: AppStore, code: GitHubDeviceCode, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    var failure by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(code) {
        try { store.github.finishSignIn(code); onDismiss() }
        catch (e: CancellationException) { throw e }
        catch (e: GitHubDeclined) { onDismiss() }
        catch (e: Exception) { failure = e.message }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Sign In with GitHub") },
        text = {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Enter this code on GitHub", color = MaterialTheme.colorScheme.onSurfaceVariant)
                androidx.compose.foundation.text.selection.SelectionContainer {
                    Text(code.userCode, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, fontSize = 32.sp, modifier = Modifier.testTag("github.code"))
                }
                Button(onClick = {
                    scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("GitHub code", code.userCode))) }
                    copied = true
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(code.verificationURL)))
                }, modifier = Modifier.fillMaxWidth()) { Text("Copy Code and Open GitHub") }
                failure?.let { Text(it, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center) }
                    ?: if (copied) CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp) else Unit
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Signs in with a personal access token, for builds without a client ID or for access to a single repository. */
@Composable
private fun TokenDialog(store: AppStore, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var token by remember { mutableStateOf("") }
    var failure by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    fun signIn() = scope.launch {
        busy = true; failure = null
        try { store.github.signIn(token); onDismiss() } catch (e: CancellationException) { throw e } catch (e: Exception) { failure = e.message }
        finally { busy = false }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("GitHub Token") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(token, { token = it }, label = { Text("Token") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false), modifier = Modifier.testTag("github.tokenfield"))
                Text("A fine-grained token needs read and write access to Contents in the repository you’ll use.", style = MaterialTheme.typography.bodySmall)
                TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/settings/personal-access-tokens/new"))) }) { Text("Create a Token") }
                failure?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = {
            if (busy) CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
            else TextButton(onClick = { signIn() }, enabled = token.isNotBlank()) { Text("Sign In") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Repositories the person can write to. A public one is confirmed first, since anyone can read what's in it. */
@Composable
fun RepositoryScreen(store: AppStore, pop: () -> Unit) {
    val scope = rememberCoroutineScope()
    var repositories by remember { mutableStateOf<List<GitHubRepository>?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    var search by remember { mutableStateOf("") }
    var confirming by remember { mutableStateOf<GitHubRepository?>(null) }
    var naming by remember { mutableStateOf(false) }
    var creating by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    suspend fun load() {
        try { repositories = store.github.repositories(); failure = null } catch (e: CancellationException) { throw e } catch (e: Exception) { failure = e.message }
    }
    fun choose(repository: GitHubRepository) { store.github.choose(repository); pop() }
    LaunchedEffect(Unit) { load() }

    SubScreen("Repository", pop) { modifier ->
        PullToRefreshBox(refreshing, onRefresh = { scope.launch { refreshing = true; load(); refreshing = false } }, modifier = modifier) {
            LazyColumn(Modifier.fillMaxSize()) {
                item {
                    OutlinedTextField(search, { search = it }, placeholder = { Text("Search") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp))
                }
                item {
                    Group {
                        ActionRow("New Private Repository", color = MaterialTheme.colorScheme.primary, enabled = !creating,
                            trailing = { if (creating) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else Icon(Icons.Outlined.Add, null) }) { naming = true }
                    }
                }
                failure?.let { item { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp)) } }
                val list = repositories
                if (list == null && failure == null) item { CircularProgressIndicator(Modifier.padding(32.dp)) }
                val query = search.trim()
                items(list.orEmpty().filter { query.isEmpty() || it.fullName.contains(query, ignoreCase = true) }, key = { it.fullName }) { repository ->
                    ListItem(
                        leadingContent = { Icon(if (repository.isPrivate) Icons.Outlined.Lock else Icons.Outlined.Public, null) },
                        headlineContent = { Text(repository.fullName) },
                        trailingContent = {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                if (!repository.isPrivate) Text("Public", color = Warning)
                                if (store.github.connection?.repository?.fullName == repository.fullName) Icon(Icons.Outlined.Check, "Selected", tint = MaterialTheme.colorScheme.primary)
                            }
                        },
                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                        modifier = Modifier.widthIn(max = 900.dp).clickable { if (repository.isPrivate) choose(repository) else confirming = repository },
                    )
                }
            }
        }
    }

    confirming?.let { repository ->
        AlertDialog(
            onDismissRequest = { confirming = null },
            icon = { Icon(Icons.Outlined.Warning, null, tint = Warning) },
            title = { Text("Use a Public Repository?") },
            text = { Text("Anyone on GitHub will be able to read your drafts, including ones you never post.") },
            confirmButton = { TextButton(onClick = { confirming = null; choose(repository) }) { Text("Use ${repository.fullName}") } },
            dismissButton = { TextButton(onClick = { confirming = null }) { Text("Cancel") } },
        )
    }
    if (naming) TextDialog("New Private Repository", "quill-drafts", action = "Create", label = "Name", keyboard = KeyboardType.Ascii, onDismiss = { naming = false }) { name ->
        naming = false
        scope.launch {
            creating = true
            try { choose(store.github.createRepository(name.trim())) } catch (e: CancellationException) { throw e } catch (e: Exception) { failure = e.message }
            finally { creating = false }
        }
    }
}

