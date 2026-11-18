package com.quillnative.android

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.quillnative.core.Attachment
import kotlinx.coroutines.delay
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.concurrent.thread
import kotlin.math.log10
import kotlin.math.sqrt

/** Records a voice note and writes it out as text while you speak. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceNoteSheet(attachRecording: Boolean, onDismiss: () -> Unit, onFinish: (String, Attachment?) -> Unit) {
    val context = LocalContext.current
    val storage = remember { Storage.get(context) }
    var attach by remember { mutableStateOf(storage.bool("attachVoiceRecordings") ?: false) }
    val recorder = remember { VoiceRecorder(context) }
    var allowed by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        allowed = granted
        if (!granted) recorder.failure = "Allow microphone access in Settings to record voice notes."
    }
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    LaunchedEffect(allowed) { if (allowed) recorder.start(keepAudio = attach && attachRecording) else ask.launch(Manifest.permission.RECORD_AUDIO) }
    LaunchedEffect(recorder.recording) { while (recorder.recording) { delay(250); recorder.tick() } }
    DisposableEffect(Unit) { onDispose { recorder.discard() } }

    ModalBottomSheet(onDismissRequest = { recorder.discard(); onDismiss() }, sheetState = sheet) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            val failure = recorder.failure
            if (failure != null) {
                Text(failure, color = MaterialTheme.colorScheme.error, modifier = Modifier.fillMaxWidth().padding(vertical = 32.dp))
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    LevelMeter(recorder.levels, Modifier.weight(1f).height(32.dp))
                    val seconds = recorder.elapsed / 1000
                    Text("%d:%02d".format(seconds / 60, seconds % 60), color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyLarge.copy(fontFeatureSettings = "tnum"), modifier = Modifier.padding(start = 12.dp))
                }
                Box(Modifier.fillMaxWidth().heightIn(min = 120.dp, max = 260.dp).verticalScroll(rememberScrollState())) {
                    val text = recorder.transcript
                    if (text.isEmpty()) Text(if (recorder.recording) "Listening…" else "Starting…", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.titleMedium)
                    else Text(text, style = MaterialTheme.typography.titleMedium)
                }
            }
            if (attachRecording) {
                SwitchRow("Attach Recording", attach, subtitle = if (!VoiceRecorder.canRecordWhileTranscribing) "Turns off live transcription before Android 13." else null) {
                    attach = it
                    storage.setBool("attachVoiceRecordings", it)
                    recorder.restart(keepAudio = it)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = { recorder.discard(); onDismiss() }, modifier = Modifier.weight(1f).height(52.dp)) { Text("Cancel") }
                Button(
                    onClick = { recorder.stop { text, audio -> onFinish(text, audio) } },
                    enabled = recorder.recording, modifier = Modifier.weight(1f).height(52.dp).testTag("voice.done"),
                ) { Icon(Icons.Outlined.Stop, null, Modifier.size(20.dp)); Text("  Done") }
            }
        }
    }
}

@Composable
private fun LevelMeter(levels: List<Float>, modifier: Modifier) {
    val color = MaterialTheme.colorScheme.primary
    Canvas(modifier) {
        val count = 32
        val gap = 3.dp.toPx()
        val width = (size.width - gap * (count - 1)) / count
        val values = levels.takeLast(count)
        for (i in 0 until count) {
            val level = values.getOrNull(i - (count - values.size)) ?: 0f
            val height = maxOf(width, size.height * level)
            drawRoundRect(color.copy(alpha = 0.35f + 0.65f * level), Offset(i * (width + gap), (size.height - height) / 2), Size(width, height), CornerRadius(width / 2))
        }
    }
}

/**
 * Captures the microphone and transcribes it with the system speech recognizer.
 * From Android 13 the recognizer reads the same audio Quill records, so a recording can be kept too.
 */
class VoiceRecorder(private val context: Context) {
    var recording by mutableStateOf(false); private set
    var failure by mutableStateOf<String?>(null)
    var transcript by mutableStateOf(""); private set
    var elapsed by mutableLongStateOf(0L); private set
    val levels = mutableStateListOf<Float>()
    private var level by mutableFloatStateOf(0f)

    private var committed = ""
    private var partial = ""
    private var started = 0L
    private var recognizer: SpeechRecognizer? = null
    private var audio: AudioRecord? = null
    private var pipe: ParcelFileDescriptor.AutoCloseOutputStream? = null
    private val pcm = ByteArrayOutputStream()
    private var keepAudio = false
    private var useOwnAudio = false
    @Volatile private var running = false
    private var finishing: ((String, Attachment?) -> Unit)? = null

    companion object {
        const val RATE = 16_000
        val canRecordWhileTranscribing = Build.VERSION.SDK_INT >= 33
    }

    fun start(keepAudio: Boolean) {
        if (recording) return
        this.keepAudio = keepAudio
        val canTranscribe = SpeechRecognizer.isRecognitionAvailable(context)
        if (!canTranscribe && !keepAudio) { failure = "Speech recognition isn’t available on this device."; return }
        useOwnAudio = keepAudio
        started = System.currentTimeMillis()
        running = true
        recording = true
        if (useOwnAudio && !startAudio()) return
        // Before Android 13 the recognizer and a recording can't share the microphone, so a kept recording goes untranscribed.
        if (canTranscribe && (canRecordWhileTranscribing || !keepAudio)) listen()
    }

    fun restart(keepAudio: Boolean) {
        if (keepAudio == this.keepAudio) return
        // The transcript so far stays; only what is kept from here changes.
        committed = text()
        partial = ""
        teardown()
        pcm.reset()
        recording = false
        start(keepAudio)
    }

    fun tick() { elapsed = System.currentTimeMillis() - started }

    private fun text() = listOf(committed, partial).filter { it.isNotBlank() }.joinToString(" ").trim()

    @SuppressLint("MissingPermission")
    private fun startAudio(): Boolean {
        val size = maxOf(AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT), RATE / 5)
        val record = runCatching { AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, size) }.getOrNull()
        if (record == null || record.state != AudioRecord.STATE_INITIALIZED) { failure = "The microphone couldn’t be opened."; recording = false; return false }
        audio = record
        record.startRecording()
        thread(name = "quill-voice") {
            val buffer = ByteArray(size)
            while (running) {
                val read = record.read(buffer, 0, buffer.size)
                if (read <= 0) continue
                if (keepAudio) synchronized(pcm) { pcm.write(buffer, 0, read) }
                runCatching { pipe?.write(buffer, 0, read) }
                meter(buffer, read)
            }
        }
        return true
    }

    private fun meter(buffer: ByteArray, read: Int) {
        val samples = ByteBuffer.wrap(buffer, 0, read).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        var sum = 0.0
        val n = samples.remaining()
        while (samples.hasRemaining()) { val s = samples.get() / 32768.0; sum += s * s }
        val rms = sqrt(sum / maxOf(1, n))
        val db = 20 * log10(maxOf(rms, 1e-5))
        android.os.Handler(context.mainLooper).post { push(((db + 50) / 50).toFloat().coerceIn(0f, 1f)) }
    }

    private fun push(value: Float) {
        level = value
        levels.add(value)
        if (levels.size > 64) levels.removeAt(0)
    }

    /** Starts one listening session; a new one begins each time the recognizer finishes a phrase. */
    private fun listen() {
        if (!running) return
        val speech = recognizer ?: SpeechRecognizer.createSpeechRecognizer(context).also { recognizer = it }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 4000L)
        if (useOwnAudio && Build.VERSION.SDK_INT >= 33) {
            runCatching { pipe?.close() }
            val (read, write) = ParcelFileDescriptor.createPipe().let { it[0] to it[1] }
            pipe = ParcelFileDescriptor.AutoCloseOutputStream(write)
            intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, read)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, RATE)
        }
        speech.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) { if (!useOwnAudio) push(((rmsdB + 2) / 12).coerceIn(0f, 1f)) }
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onError(error: Int) {
                when (error) {
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> again()
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> failure = "Allow microphone access in Settings to record voice notes."
                    SpeechRecognizer.ERROR_CLIENT -> {}
                    else -> if (transcript.isEmpty() && !keepAudio) failure = "Speech couldn’t be transcribed. Try again." else again()
                }
            }
            override fun onResults(results: Bundle?) {
                val best = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                partial = ""
                committed = listOf(committed, best).filter { it.isNotBlank() }.joinToString(" ")
                transcript = text()
                again()
            }
            override fun onPartialResults(results: Bundle?) {
                partial = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                transcript = text()
            }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        speech.startListening(intent)
    }

    private fun again() {
        finishing?.let { done -> finishing = null; finish(done); return }
        if (running) listen()
    }

    /** Stops listening and hands back the transcript, and the recording when it is kept. */
    fun stop(done: (String, Attachment?) -> Unit) {
        if (!recording) return
        val speech = recognizer
        if (speech == null) { finish(done); return }
        // Gives the recognizer a moment to return the last words.
        finishing = done
        runCatching { pipe?.close() }; pipe = null
        speech.stopListening()
        android.os.Handler(context.mainLooper).postDelayed({ finishing?.let { finishing = null; finish(it) } }, 1500)
    }

    private fun finish(done: (String, Attachment?) -> Unit) {
        val text = text()
        val kept = if (keepAudio) synchronized(pcm) { pcm.toByteArray() } else null
        teardown()
        recording = false
        done(text, kept?.takeIf { it.isNotEmpty() }?.let { Attachment(data = wav(it), filename = "voice-${UUID.randomUUID().toString().take(8)}.wav", mimeType = "audio/wav") })
    }

    fun discard() {
        finishing = null
        teardown()
        pcm.reset()
        recording = false
    }

    private fun teardown() {
        running = false
        runCatching { pipe?.close() }; pipe = null
        recognizer?.let { runCatching { it.cancel(); it.destroy() } }; recognizer = null
        audio?.let { runCatching { it.stop() }; it.release() }; audio = null
    }

    private fun wav(pcm: ByteArray): ByteArray {
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVE".toByteArray())
        header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(RATE).putInt(RATE * 2).putShort(2).putShort(16)
        header.put("data".toByteArray()).putInt(pcm.size)
        return header.array() + pcm
    }
}

