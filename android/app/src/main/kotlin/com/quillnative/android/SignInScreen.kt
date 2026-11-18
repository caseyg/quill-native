package com.quillnative.android

import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.quillnative.core.WebUrl
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable
fun SignInScreen(store: AppStore, activity: MainActivity) {
    var site by rememberSaveable { mutableStateOf("") }
    var token by rememberSaveable { mutableStateOf("") }
    var usesToken by rememberSaveable { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var attempts by remember { mutableIntStateOf(0) }
    val browserFailure by activity.signInFailure
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val focus = LocalFocusManager.current
    val haptics = LocalHapticFeedback.current
    val tokenFocus = remember { FocusRequester() }
    val shake = remember { Animatable(0f) }

    LaunchedEffect(browserFailure) {
        browserFailure?.let { failure = it; attempts++; activity.signInFailure.value = null }
    }
    LaunchedEffect(attempts) {
        if (attempts == 0) return@LaunchedEffect
        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        for (x in listOf(12f, -10f, 6f, -3f, 0f)) shake.animateTo(x, spring(stiffness = 3000f))
    }

    val canSubmit = runCatching { WebUrl.site(site) }.isSuccess && (!usesToken || token.isNotEmpty()) && !store.busy

    fun signIn() {
        if (!canSubmit) return
        focus.clearFocus()
        failure = null
        scope.launch {
            try {
                if (usesToken) store.signIn(site, token)
                else {
                    val url = store.startSignIn(site)
                    CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, Uri.parse(url))
                }
            } catch (e: CancellationException) { throw e } catch (e: Exception) {
                failure = e.message ?: "Sign-in failed."; attempts++
            }
        }
    }

    Column(
        Modifier.fillMaxSize().safeDrawingPadding().imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(72.dp))
        Icon(Icons.Outlined.Edit, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(48.dp))
        Spacer(Modifier.height(12.dp))
        Text("Quill", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(32.dp))
        Column(
            Modifier.widthIn(max = 440.dp).fillMaxWidth().offset { IntOffset(shake.value.dp.roundToPx(), 0) },
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = site, onValueChange = { site = it }, singleLine = true,
                label = { Text("Website") }, placeholder = { Text("yourdomain.com") },
                modifier = Modifier.fillMaxWidth().testTag("login.site"),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false,
                    imeAction = if (usesToken) ImeAction.Next else ImeAction.Go),
                keyboardActions = KeyboardActions(onNext = { tokenFocus.requestFocus() }, onGo = { signIn() }),
            )
            AnimatedVisibility(usesToken) {
                OutlinedTextField(
                    value = token, onValueChange = { token = it }, singleLine = true, label = { Text("Access token") },
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth().focusRequester(tokenFocus).testTag("login.token"),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { signIn() }),
                )
            }
            AnimatedVisibility(failure != null) {
                Text(failure.orEmpty(), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(horizontal = 4.dp).testTag("login.error"))
            }
            Button(onClick = ::signIn, enabled = canSubmit, shape = CircleShape, modifier = Modifier.fillMaxWidth().height(52.dp).testTag("login.button")) {
                if (store.busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else Text("Sign In", style = MaterialTheme.typography.titleMedium)
            }
            TextButton(onClick = { usesToken = !usesToken; failure = null }, modifier = Modifier.align(Alignment.CenterHorizontally).testTag("login.mode")) {
                Text(if (usesToken) "Sign In with IndieAuth" else "Use an Access Token")
            }
        }
    }
}
