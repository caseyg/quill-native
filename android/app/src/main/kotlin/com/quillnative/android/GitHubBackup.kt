package com.quillnative.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.quillnative.core.Draft
import com.quillnative.core.DraftMirror
import com.quillnative.core.GitHubClient
import com.quillnative.core.GitHubDeviceCode
import com.quillnative.core.GitHubDeviceFlow
import com.quillnative.core.GitHubRepository
import com.quillnative.core.QuillException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/** Keeps a copy of every draft in a GitHub repository the person picks. Separate from posting to their site. */
class GitHubBackup(private val storage: Storage, private val scope: CoroutineScope, private val drafts: () -> List<Draft>) {
    @Serializable
    data class Connection(val login: String, val repository: GitHubRepository? = null, val folder: String = "drafts")

    var connection by mutableStateOf(storage.read(Connection.serializer(), "github"))
        private set
    var syncing by mutableStateOf(false)
        private set
    var synced by mutableStateOf(storage.long("githubSynced"))
        private set
    /** The last failure, shown in Settings. Drafts stay on the device and are tried again on the next save. */
    var problem by mutableStateOf<String?>(null)
        private set

    private var pending: Job? = null
    private var again = false
    private val tokenAccount = "github:token"

    val isOn: Boolean get() = connection?.repository != null
    private val client: GitHubClient? get() = storage.secrets.token(tokenAccount)?.let(::GitHubClient)

    companion object {
        /** The OAuth app's public client ID. Without one, only a token can be used. */
        val clientId: String? = BuildConfig.QUILL_GITHUB_CLIENT_ID.trim().ifEmpty { null }
    }

    // Signing in

    suspend fun startSignIn(): GitHubDeviceCode {
        val id = clientId ?: throw QuillException("This build has no GitHub client ID. Use a token instead.")
        return GitHubDeviceFlow().start(id)
    }

    suspend fun finishSignIn(code: GitHubDeviceCode) {
        val id = clientId ?: return
        signIn(GitHubDeviceFlow().token(id, code))
    }

    suspend fun signIn(token: String) {
        val value = token.trim()
        if (value.isEmpty()) throw QuillException("Enter a token.")
        val login = GitHubClient(value).login()
        storage.secrets.save(value, tokenAccount)
        save(Connection(login))
        problem = null
    }

    /** Forgets the sign-in and the repository. Files already in the repository stay there. */
    fun disconnect() {
        pending?.cancel(); pending = null
        storage.secrets.delete(tokenAccount)
        storage.write(Connection.serializer(), "github", null)
        storage.write(DraftMirror.serializer(), "githubMirror", null)
        storage.setLong("githubSynced", null)
        connection = null; synced = null; problem = null
    }

    // Repository

    suspend fun repositories(): List<GitHubRepository> = (client ?: throw QuillException("Sign in to GitHub first.")).repositories()

    suspend fun createRepository(name: String): GitHubRepository = (client ?: throw QuillException("Sign in to GitHub first.")).createPrivateRepository(name)

    /** Starts copying every draft to this repository. */
    fun choose(repository: GitHubRepository) {
        val current = connection ?: return
        save(current.copy(repository = repository))
        problem = null
        schedule(0)
    }

    fun setFolder(folder: String) {
        val current = connection ?: return
        val normalized = DraftMirror.normalize(folder)
        if (normalized == current.folder) return
        save(current.copy(folder = normalized))
        schedule(0)
    }

    private fun save(value: Connection) {
        connection = value
        storage.write(Connection.serializer(), "github", value)
    }

    // Syncing

    /** Sends draft changes shortly, so several saves in a row become one pass. */
    fun schedule(delayMillis: Long = 1000) {
        if (!isOn) return
        if (syncing) { again = true; return }
        pending?.cancel()
        pending = scope.launch { delay(delayMillis); sync() }
    }

    suspend fun sync() {
        val connection = connection ?: return
        val repository = connection.repository ?: return
        val client = client ?: return
        if (syncing) return
        syncing = true
        try {
            var mirror = storage.read(DraftMirror.serializer(), "githubMirror") ?: DraftMirror.create(repository.fullName, connection.folder)
            // Another repository or folder starts over. What is in the old one stays there.
            if (mirror.repository != repository.fullName || mirror.folder != DraftMirror.normalize(connection.folder)) {
                mirror = DraftMirror.create(repository.fullName, connection.folder)
            }
            val steps = mirror.plan(drafts())
            if (steps.isNotEmpty()) {
                // A repository made public since it was chosen should say so in Settings.
                val current = client.repository(repository.fullName)
                if (current != repository && this.connection?.repository == repository) save(connection.copy(repository = current))
            }
            for (step in steps) {
                for ((path, data) in step.writes) {
                    stillWriting(mirror)
                    val sha = client.put(path, data, "Save draft: ${step.title}", mirror.drafts[step.id]?.files?.get(path), mirror.repository)
                    stillWriting(mirror)
                    mirror = mirror.wrote(path, sha, step.id); store(mirror)
                }
                for ((path, sha) in step.removals) {
                    stillWriting(mirror)
                    client.delete(path, "Remove draft: ${step.title}", sha, mirror.repository)
                    stillWriting(mirror)
                    mirror = mirror.removed(path, step.id); store(mirror)
                }
                mirror = mirror.finished(step); store(mirror)
            }
            problem = null
            synced = System.currentTimeMillis(); storage.setLong("githubSynced", synced)
        } catch (e: CancellationException) {
            // Disconnected or moved while writing.
        } catch (e: Exception) {
            problem = e.message
        } finally {
            syncing = false
            if (again) { again = false; schedule() }
        }
    }

    /** Stops a pass when the person disconnects or picks another repository or folder while it runs. */
    private fun stillWriting(mirror: DraftMirror) {
        val c = connection
        if (c == null || c.repository?.fullName != mirror.repository || DraftMirror.normalize(c.folder) != mirror.folder) throw CancellationException()
    }

    private fun store(mirror: DraftMirror) = storage.write(DraftMirror.serializer(), "githubMirror", mirror)
}
