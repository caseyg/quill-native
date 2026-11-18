package com.quillnative.android

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import androidx.core.content.FileProvider
import com.quillnative.core.Attachment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import kotlin.coroutines.resume

object Media {
    /** Reads a picked photo as a JPEG, turned the way it was taken. */
    suspend fun photo(context: Context, uri: Uri, name: String = "photo"): Attachment? = withContext(Dispatchers.IO) {
        runCatching {
            val bitmap: Bitmap = if (Build.VERSION.SDK_INT >= 28) {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, _, _ ->
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }
            } else {
                context.contentResolver.openInputStream(uri)!!.use { BitmapFactory.decodeStream(it) }
            }
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
            Attachment(data = out.toByteArray(), filename = "$name-${UUID.randomUUID().toString().take(8)}.jpg", mimeType = "image/jpeg")
        }.getOrNull()
    }

    /** A file the camera can write a new photo into. */
    fun cameraFile(context: Context): Pair<File, Uri> {
        val directory = File(context.cacheDir, "camera").apply { mkdirs() }
        val file = File(directory, "photo-${UUID.randomUUID()}.jpg")
        return file to FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    }

    /** One fix of where the device is now, or null when it can't be found in time. */
    @SuppressLint("MissingPermission")
    suspend fun currentLocation(context: Context): Location? {
        val manager = context.getSystemService(LocationManager::class.java) ?: return null
        val provider = listOf(LocationManager.FUSED_PROVIDER, LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .firstOrNull { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) } ?: return null
        val recent = runCatching { manager.getLastKnownLocation(provider) }.getOrNull()
        if (recent != null && System.currentTimeMillis() - recent.time < 120_000) return recent
        return withTimeoutOrNull(20_000) {
            suspendCancellableCoroutine { continuation ->
                if (Build.VERSION.SDK_INT >= 30) {
                    val signal = CancellationSignal()
                    continuation.invokeOnCancellation { signal.cancel() }
                    manager.getCurrentLocation(provider, signal, context.mainExecutor) { continuation.resume(it ?: recent) }
                } else {
                    @Suppress("DEPRECATION")
                    manager.requestSingleUpdate(provider, { continuation.resume(it) }, context.mainLooper)
                }
            }
        } ?: recent
    }
}
