package com.quillnative.android

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import com.quillnative.core.Draft

/** Screens pushed over the post list. */
enum class Screen { SETTINGS, POST_TYPES, ADVANCED, GITHUB, REPOSITORIES }

@Composable
fun Root(store: AppStore, activity: MainActivity) {
    val signedIn = store.account != null
    Crossfade(signedIn, label = "account") { on ->
        if (!on) SignInScreen(store, activity) else Main(store, activity)
    }
    store.error?.let { message ->
        AlertDialog(
            onDismissRequest = { store.error = null },
            confirmButton = { TextButton(onClick = { store.error = null }) { Text("OK") } },
            text = { Text(message) },
        )
    }
}

@Composable
private fun Main(store: AppStore, activity: MainActivity) {
    val stack = remember { mutableStateListOf<Screen>() }
    val showSettings by activity.showSettings
    LaunchedEffect(showSettings) {
        if (showSettings) { if (stack.isEmpty()) stack.add(Screen.SETTINGS); activity.showSettings.value = false }
    }
    Box(Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = stack.lastOrNull(),
            transitionSpec = {
                val forward = (targetState?.ordinal ?: -1) > (initialState?.ordinal ?: -1)
                (slideInHorizontally { if (forward) it / 3 else -it / 3 } + fadeIn()) togetherWith (slideOutHorizontally { if (forward) -it / 3 else it / 3 } + fadeOut())
            },
            label = "screens",
        ) { screen ->
            Surface(color = MaterialTheme.colorScheme.background) {
                val push: (Screen) -> Unit = { stack.add(it) }
                val pop: () -> Unit = { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
                when (screen) {
                    null -> HomeScreen(store, openSettings = { stack.add(Screen.SETTINGS) })
                    Screen.SETTINGS -> SettingsScreen(store, push, pop)
                    Screen.POST_TYPES -> PostTypesScreen(store, pop)
                    Screen.ADVANCED -> AdvancedScreen(store, pop)
                    Screen.GITHUB -> GitHubScreen(store, push, pop)
                    Screen.REPOSITORIES -> RepositoryScreen(store, pop)
                }
            }
        }
        BackHandler(enabled = stack.isNotEmpty() && store.composer == null) { stack.removeAt(stack.lastIndex) }

        AnimatedVisibility(
            visible = store.composer != null,
            enter = slideInVertically { it / 4 } + fadeIn(),
            exit = slideOutVertically { it / 4 } + fadeOut(),
        ) {
            // Keeps the last draft on screen while the composer animates away.
            val holder = remember { arrayOfNulls<Draft>(1) }
            store.composer?.let { holder[0] = it }
            val draft = holder[0]
            if (draft != null) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    key(draft.id) { ComposerScreen(store, draft, onClose = { store.composer = null }) }
                }
            }
        }
    }
}
