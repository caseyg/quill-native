package com.quillnative.android

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.quillnative.core.Account
import com.quillnative.core.Draft
import com.quillnative.core.Form
import com.quillnative.core.HttpRequest
import com.quillnative.core.IndieAuthRequest
import com.quillnative.core.Library
import com.quillnative.core.LibrarySync
import com.quillnative.core.MicropubClient
import com.quillnative.core.Network
import com.quillnative.core.PageSummary
import com.quillnative.core.Payload
import com.quillnative.core.Post
import com.quillnative.core.PostKind
import com.quillnative.core.Preferences
import com.quillnative.core.QuillException
import com.quillnative.core.Receipt
import com.quillnative.core.ServerConfig
import com.quillnative.core.SignInDiscovery
import com.quillnative.core.TokenSignIn
import com.quillnative.core.WebUrl
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlin.coroutines.cancellation.CancellationException

/** The app's state and everything that changes it. The Android counterpart of the iOS AppStore. */
class AppStore(context: Context) {
    val storage = Storage.get(context)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    var account by mutableStateOf(storage.read(Account.serializer(), "account"))
        private set
    var preferences by mutableStateOf(storage.read(Preferences.serializer(), "preferences") ?: Preferences())
        private set
    var config by mutableStateOf(ServerConfig())
        private set
    var drafts by mutableStateOf(emptyList<Draft>())
        private set
    var receipts by mutableStateOf(storage.read(ListSerializer(Receipt.serializer()), "receipts") ?: emptyList())
        private set
    /** Posts from the site, kept on device for browsing, search and editing. */
    var library by mutableStateOf(Library())
        private set
    /** Whether posts are kept on this device. Null until the person has been asked. */
    var syncEnabled by mutableStateOf(storage.bool("syncEnabled"))
        private set
    /** Shows the question about keeping posts on this device. */
    var askingToSync by mutableStateOf(false)
    var syncing by mutableStateOf(false)
        private set
    var syncProgress by mutableStateOf<SyncProgress?>(null)
        private set
    /** The post being fetched for editing. */
    var opening by mutableStateOf<String?>(null)
        private set
    var composer by mutableStateOf<Draft?>(null)
    /** Opens the next composer straight into recording. */
    var startsVoiceNote by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var busy by mutableStateOf(false)
        private set
    /** Counts posts sent, for a confirmation. */
    var sent by mutableStateOf(0)
        private set

    val github = GitHubBackup(storage, scope) { drafts }

    private var syncJob: Job? = null
    private var pendingAuth: IndieAuthRequest? = null
    /** Posts sent this session, kept in the list until a sync includes them. */
    private val recentlySent = mutableSetOf<String>()
    private val describing = mutableSetOf<String>()
    private var pendingSave: Job? = null

    data class SyncProgress(val count: Int, val fraction: Double?)

    val client: MicropubClient? get() {
        val account = account ?: return null
        val token = storage.secrets.token(account.me) ?: return null
        return MicropubClient(account.micropub, token)
    }

    init {
        reloadDrafts()
        // Libraries downloaded before syncing was a choice stay on.
        if (syncEnabled == null && account != null && libraryStore()?.load()?.synced != null) setSync(true, starting = false)
        loadLibrary()
    }

    fun updatePreferences(change: (Preferences) -> Preferences) {
        preferences = change(preferences)
        storage.write(Preferences.serializer(), "preferences", preferences)
    }

    // Account

    /** Starts IndieAuth and returns the address to open in the browser. The browser comes back through [finishSignIn]. */
    suspend fun startSignIn(site: String): String {
        busy = true
        try {
            val configuration = SignInDiscovery.discover(site)
            val request = IndieAuthRequest.start(configuration, BuildConfig.QUILL_CLIENT_ID)
            pendingAuth = request
            return request.authorizationURL
        } finally { busy = false }
    }

    val waitingForBrowser: Boolean get() = pendingAuth != null

    /** Called with the quill-native://oauth address the browser opened. */
    fun finishSignIn(callback: String, onFailure: (String) -> Unit) {
        val request = pendingAuth ?: return onFailure("Sign-in took too long. Try again.")
        pendingAuth = null
        scope.launch {
            busy = true
            try {
                val (account, token) = request.finish(callback)
                signedIn(account, token)
            } catch (e: CancellationException) { throw e } catch (e: Exception) {
                onFailure(e.message ?: "Sign-in failed.")
            } finally { busy = false }
        }
    }

    fun cancelSignIn() { pendingAuth = null }

    suspend fun signIn(site: String, token: String) {
        busy = true
        try {
            val (account, config) = TokenSignIn.discover(site, token.trim())
            this.config = config
            signedIn(account, token.trim())
        } finally { busy = false }
    }

    private suspend fun signedIn(account: Account, token: String) {
        storage.secrets.save(token, account.me)
        storage.write(Account.serializer(), "account", account)
        this.account = account
        loadLibrary()
        refresh(asking = true)
    }

    /** Reloads the server's settings without syncing, for the share sheet. */
    suspend fun loadConfig() {
        val client = client ?: return
        runCatching { client.configuration() }.getOrNull()?.let { config = it }
    }

    /** Reloads the server's settings and fetches new posts. `asking` offers to sync when it is off. */
    suspend fun refresh(asking: Boolean = false) {
        val client = client ?: return
        runCatching { client.configuration() }.getOrNull()?.let { config = it }
        if (syncEnabled != true) { askingToSync = asking; return }
        // Only posts newer than the ones on device; a first download runs on without holding the refresh.
        if (library.isComplete) sync() else startSync()
    }

    /** Turns keeping posts on device on or off. Off deletes the posts kept here; the site is not touched. */
    fun setSync(on: Boolean, starting: Boolean = true) {
        syncEnabled = on
        storage.setBool("syncEnabled", on)
        if (on) { if (starting) startSync() } else {
            syncJob?.cancel(); syncJob = null
            libraryStore()?.delete()
            loadLibrary()
        }
    }

    /** Downloads every post again, which also drops posts deleted on the site. */
    fun syncEverything() {
        library = library.copy(complete = false)
        startSync()
    }

    private fun startSync() {
        if (syncJob?.isActive == true) return
        syncJob = scope.launch { sync() }
    }

    // Library

    private fun libraryStore() = account?.let { storage.library(it.me) }

    fun loadLibrary() {
        var loaded = if (syncEnabled == true) libraryStore()?.load() ?: Library() else Library()
        // Posts sent before the library existed.
        for (receipt in receipts.reversed()) {
            if (receipt.accountURL != null && receipt.accountURL != account?.me) continue
            if (loaded.posts.any { it.url == receipt.url }) continue
            loaded = loaded.copy(posts = loaded.posts + Post(receipt.url, receipt.kind, name = receipt.title, published = receipt.date))
        }
        library = loaded
    }

    /** Fetches posts newer than the ones on device, or every post when the library is new or unfinished. Failures keep what is here. */
    suspend fun sync() {
        val account = account ?: return
        val client = client ?: return
        if (syncEnabled != true || syncing) return
        syncing = true
        val incremental = library.isComplete
        val known = if (incremental) library.posts.map { it.id }.toSet() else emptySet()
        // Dates of posts already on device let the bar show how far back the sync has reached.
        val oldest = library.posts.mapNotNull { it.published }.minOrNull()
        if (!incremental) syncProgress = SyncProgress(0, if (oldest == null) null else 0.0)
        try {
            val result = LibrarySync.fetch(client, account.me, known = known) { page ->
                withContext(Dispatchers.Main) { received(page, oldest, !incremental, account) }
            }
            if (this.account != account || syncEnabled != true) return
            // A sync that began before a post was sent may not include it yet.
            val fetched = result.posts.map { it.url }.toSet()
            val sent = library.posts.filter { it.url in recentlySent && it.url !in fetched }
            recentlySent.removeAll(fetched)
            library = library.replacing(sent + result.posts, result.source, keeping = incremental, complete = result.finished)
            saveLibrary()
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            if (library.posts.isEmpty()) error = e.message
        } finally {
            syncing = false; syncProgress = null
        }
    }

    /** Shows each page as it arrives. A first sync lists posts right away instead of after the last page. */
    private fun received(page: List<Post>, oldest: Long?, filling: Boolean, account: Account) {
        if (this.account != account || syncEnabled != true) return
        val progress = syncProgress ?: return
        var fraction = progress.fraction
        val reached = page.mapNotNull { it.published }.minOrNull()
        if (oldest != null && reached != null) {
            val now = System.currentTimeMillis()
            val span = (now - oldest).toDouble()
            if (span > 0) fraction = maxOf(fraction ?: 0.0, minOf(1.0, (now - reached) / span))
        }
        syncProgress = SyncProgress(progress.count + page.size, fraction)
        if (filling) {
            val known = library.posts.map { it.id }.toSet()
            library = library.copy(posts = library.posts + page.filter { it.id !in known })
        }
    }

    /** Writes the library away from the main thread. */
    private fun saveLibrary() {
        if (syncEnabled != true) return
        val store = libraryStore() ?: return
        val snapshot = library
        scope.launch(Dispatchers.IO) { runCatching { store.save(snapshot) } }
    }

    /** Reads the author and text of the page a like, repost, reply or bookmark points to, once. */
    suspend fun describe(post: Post) {
        if (!post.needsCite) return
        val url = WebUrl.parseOrNull(post.target) ?: return
        if (!describing.add(post.id)) return
        try {
            // Only HTML is read, and only the first 2 MB, since the page is untrusted.
            val response = runCatching { Network.send(HttpRequest(url, timeoutMillis = 15_000), 2_000_000) }.getOrNull()
            val summary = if (response != null && response.status in 200..299 && (response.header("Content-Type") ?: "text/html").lowercase().contains("html"))
                PageSummary.parse(response.text) else PageSummary.Summary("", "")
            val index = library.posts.indexOfFirst { it.id == post.id }
            if (index < 0) return
            library = library.copy(posts = library.posts.toMutableList().also { it[index] = it[index].copy(citeAuthor = summary.author, citeText = summary.text) })
            // Rows fill in quickly while scrolling, so write to disk once they settle.
            pendingSave?.cancel()
            pendingSave = scope.launch { delay(2000); saveLibrary() }
        } finally { describing.remove(post.id) }
    }

    fun edit(post: Post) {
        val client = client ?: return
        if (opening != null) return
        opening = post.id
        scope.launch {
            try { composer = client.source(post.url).copy(accountURL = account?.me) }
            catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message }
            finally { opening = null }
        }
    }

    fun edit(address: String) {
        val client = client ?: return
        scope.launch {
            busy = true
            try { composer = client.source(WebUrl.site(address)).copy(accountURL = account?.me) }
            catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message }
            finally { busy = false }
        }
    }

    fun delete(post: Post) {
        val account = account ?: return
        val client = client ?: return
        if (!account.permits("delete")) { error = "Your site didn’t grant permission to delete posts. Sign in again."; return }
        scope.launch {
            try {
                client.delete(post.url)
                library = library.copy(posts = library.posts.filter { it.id != post.id })
                forget(post.url)
                saveLibrary()
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message }
        }
    }

    /** Signs out here, and asks the site to revoke the token when it offers a way to. */
    fun signOut() {
        val account = account ?: return
        val token = storage.secrets.token(account.me)
        syncJob?.cancel(); syncJob = null
        libraryStore()?.delete(); library = Library()
        // The next site signed in to is asked again.
        syncEnabled = null; storage.setBool("syncEnabled", null)
        storage.secrets.delete(account.me)
        storage.write(Account.serializer(), "account", null)
        this.account = null; config = ServerConfig()
        if (token != null) scope.launch { TokenSignIn.revoke(account, token) }
    }

    // Drafts

    fun reloadDrafts() {
        drafts = runCatching { storage.drafts.load() }.getOrElse { error = it.message; emptyList() }
        // Every change to drafts, including ones from the share sheet, passes through here.
        github.schedule()
        Shortcuts.update(storage, drafts)
    }

    fun save(draft: Draft) {
        storage.drafts.save(draft.copy(modified = System.currentTimeMillis()))
        reloadDrafts()
    }

    fun remove(draft: Draft) {
        storage.drafts.delete(draft.id)
        reloadDrafts()
    }

    fun compose(kind: PostKind) {
        composer = Draft.create(kind, preferences, account?.me)
    }

    fun composeVoiceNote() {
        compose(PostKind.NOTE)
        startsVoiceNote = true
    }

    fun open(draft: Draft) { composer = draft }

    // Publishing

    suspend fun publish(original: Draft) {
        val account = account ?: throw QuillException("Sign in to post.")
        val client = client ?: throw QuillException("Sign in to post.")
        if (original.accountURL != null && original.accountURL != account.me) {
            throw QuillException("This draft belongs to ${WebUrl.host(original.accountURL!!) ?: "another site"}.")
        }
        val action = if (original.editURL == null) "create" else "update"
        if (!account.permits(action)) throw QuillException("Your site didn’t grant permission to $action posts. Sign in again.")
        var draft = original.copy(accountURL = account.me)
        Payload.validate(draft); save(draft)
        config.mediaEndpoint?.let { media ->
            for (index in draft.attachments.indices) {
                if (draft.attachments[index].remoteURL != null) continue
                val remote = client.upload(draft.attachments[index], media)
                draft = draft.copy(attachments = draft.attachments.toMutableList().also { it[index] = it[index].copy(remoteURL = remote) })
                save(draft) // Uploaded assets survive retry without uploading twice.
            }
        }
        val url = if (draft.editURL != null) client.update(draft, preferences) else client.create(draft, preferences)
        storage.drafts.delete(draft.id); reloadDrafts()
        receipts = listOf(Receipt.of(draft, url)) + receipts
        storage.write(ListSerializer(Receipt.serializer()), "receipts", receipts)
        // An update keeps the post's identity even if the server answers with another Location.
        var post = Post.fromDraft(draft, draft.editURL ?: url)
        library.posts.firstOrNull { it.url == post.url }?.let { old ->
            if (post.photo == null) post = post.copy(photo = old.photo, photoAlt = old.photoAlt)
            if (draft.editURL != null) post = post.copy(published = old.published)
        }
        library = library.upserting(post)
        recentlySent += post.url
        saveLibrary()
        sent++
    }

    private fun forget(url: String) {
        receipts = receipts.filter { it.url != url }
        storage.write(ListSerializer(Receipt.serializer()), "receipts", receipts)
    }

    // Routing

    /** Opens a quill-native:// link, such as `quill-native://reply?reply=https%3A%2F%2Fexample.com%2Fpost`. */
    fun handle(url: String): Route {
        val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return Route.NONE
        when (uri.host) {
            "oauth" -> return Route.OAUTH
            "settings" -> return if (account != null) Route.SETTINGS else Route.NONE
            "voice" -> { composeVoiceNote(); return Route.NONE }
        }
        reloadDrafts()
        val values = Form.decode(uri.rawQuery.orEmpty()).toMap()
        if (uri.host == "draft") {
            drafts.firstOrNull { it.id == values["id"] }?.let { open(it); return Route.NONE }
        }
        compose(PostKind.fromRaw(values["type"] ?: uri.host) ?: PostKind.NOTE)
        composer = composer?.copy(
            published = values["published"].orEmpty(),
            content = values["text"].orEmpty(),
            target = values["reply"] ?: values["url"] ?: "",
        )
        return Route.NONE
    }

    enum class Route { NONE, OAUTH, SETTINGS }

    /** Writes the draft the composer is showing after a pause, or right away when it closes. */
    fun keep(draft: Draft, saved: Draft?): Draft? {
        if (draft == saved) return saved
        if (draft.isBlank) { if (drafts.any { it.id == draft.id }) remove(draft) }
        else runCatching { save(draft) }.onFailure { error = it.message }
        return draft
    }
}
