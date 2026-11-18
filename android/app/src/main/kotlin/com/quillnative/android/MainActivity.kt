package com.quillnative.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    /** Messages from the browser after sign-in, for the sign-in screen. */
    val signInFailure = mutableStateOf<String?>(null)
    val showSettings = mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val store = store
        if (savedInstanceState == null) handle(intent)
        lifecycleScope.launch { store.refresh() }
        setContent {
            QuillTheme { Root(store, this) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onResume() {
        super.onResume()
        // Drafts saved from the share sheet appear when coming back.
        store.reloadDrafts()
    }

    private fun handle(intent: Intent?) {
        val data = intent?.data?.toString() ?: return
        if (!data.startsWith("quill-native:")) return
        when (store.handle(data)) {
            AppStore.Route.OAUTH -> store.finishSignIn(data) { signInFailure.value = it }
            AppStore.Route.SETTINGS -> showSettings.value = true
            AppStore.Route.NONE -> {}
        }
    }
}
