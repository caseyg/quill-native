package com.quillnative.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.quillnative.core.MicropubClient
import com.quillnative.core.Note
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val client = MicropubClient()

@Composable
fun QuillApp(session: SessionStore, sharedText: String?, onSharedTextUsed: () -> Unit) {
    var current by remember { mutableStateOf(session.load()) }
    val signedIn = current
    if (signedIn == null) {
        SignInScreen(onSignedIn = { session.save(it); current = it })
    } else {
        ComposeScreen(
            session = signedIn,
            sharedText = sharedText,
            onSharedTextUsed = onSharedTextUsed,
            onSignOut = { session.clear(); current = null },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SignInScreen(onSignedIn: (Session) -> Unit) {
    var site by rememberSaveable { mutableStateOf("") }
    var token by rememberSaveable { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Scaffold(topBar = { TopAppBar(title = { Text("Quill") }) }) { padding ->
        Column(
            Modifier.padding(padding).padding(16.dp).fillMaxWidth().imePadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = site, onValueChange = { site = it }, label = { Text("Your website") },
                singleLine = true, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
            )
            OutlinedTextField(
                value = token, onValueChange = { token = it }, label = { Text("Access token") },
                singleLine = true, modifier = Modifier.fillMaxWidth(),
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
            )
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(
                enabled = !busy && site.isNotBlank() && token.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
                onClick = {
                    busy = true; error = null
                    scope.launch {
                        runCatching { withContext(Dispatchers.IO) { client.discover(site) } }
                            .onSuccess { onSignedIn(Session(client.normalize(site), it.micropub, token.trim())) }
                            .onFailure { error = it.message ?: "Sign-in failed." }
                        busy = false
                    }
                },
            ) { if (busy) CircularProgressIndicator(Modifier.height(20.dp)) else Text("Sign In") }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ComposeScreen(session: Session, sharedText: String?, onSharedTextUsed: () -> Unit, onSignOut: () -> Unit) {
    var content by rememberSaveable { mutableStateOf("") }
    var tags by rememberSaveable { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    LaunchedEffect(sharedText) {
        if (sharedText != null) { content = sharedText; onSharedTextUsed() }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(session.site.removePrefix("https://").trimEnd('/')) },
                actions = { TextButton(onClick = onSignOut) { Text("Sign Out") } },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(Modifier.padding(padding).padding(16.dp).fillMaxSize().imePadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(
                value = content, onValueChange = { content = it }, placeholder = { Text("What's on your mind?") },
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
            OutlinedTextField(
                value = tags, onValueChange = { tags = it }, label = { Text("Tags") },
                singleLine = true, modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(4.dp))
            Button(
                enabled = !busy && content.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
                onClick = {
                    busy = true
                    scope.launch {
                        val note = Note(content, tags.split(','))
                        val result = runCatching { withContext(Dispatchers.IO) { client.create(session.micropub, session.token, note) } }
                        busy = false
                        result
                            .onSuccess { content = ""; tags = ""; snackbar.showSnackbar("Posted: $it") }
                            .onFailure { snackbar.showSnackbar(it.message ?: "Publishing failed.") }
                    }
                },
            ) { if (busy) CircularProgressIndicator(Modifier.height(20.dp)) else Text("Publish") }
        }
    }
}
