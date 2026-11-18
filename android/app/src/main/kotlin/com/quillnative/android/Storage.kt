package com.quillnative.android

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.quillnative.core.DraftStore
import com.quillnative.core.LibraryStore
import com.quillnative.core.QuillJson
import kotlinx.serialization.KSerializer
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Settings, drafts and the post library, in the app's private storage. Shared by the app and the share sheet. */
class Storage(context: Context) {
    private val app = context.applicationContext
    val prefs: SharedPreferences = app.getSharedPreferences("quill", Context.MODE_PRIVATE)
    val drafts = DraftStore(File(app.filesDir, "drafts"))
    val secrets = Secrets(app.getSharedPreferences("quill-secrets", Context.MODE_PRIVATE))

    fun library(me: String): LibraryStore {
        val name = me.replace(Regex("[^A-Za-z0-9]+"), "-").trim('-').take(80)
        return LibraryStore(File(app.filesDir, "library/$name.json"))
    }

    fun <T> read(serializer: KSerializer<T>, key: String): T? =
        prefs.getString(key, null)?.let { runCatching { QuillJson.decodeFromString(serializer, it) }.getOrNull() }

    fun <T> write(serializer: KSerializer<T>, key: String, value: T?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, QuillJson.encodeToString(serializer, value)) }.apply()
    }

    fun bool(key: String): Boolean? = if (prefs.contains(key)) prefs.getBoolean(key, false) else null
    fun setBool(key: String, value: Boolean?) = prefs.edit().apply { if (value == null) remove(key) else putBoolean(key, value) }.apply()
    fun long(key: String): Long? = if (prefs.contains(key)) prefs.getLong(key, 0) else null
    fun setLong(key: String, value: Long?) = prefs.edit().apply { if (value == null) remove(key) else putLong(key, value) }.apply()

    companion object {
        @Volatile private var shared: Storage? = null
        fun get(context: Context): Storage = shared ?: synchronized(this) { shared ?: Storage(context).also { shared = it } }
    }
}

/** Tokens, encrypted with a key that never leaves the Android Keystore. The counterpart of the iOS Keychain. */
class Secrets(private val prefs: SharedPreferences) {
    private val alias = "quill-tokens"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return generator.generateKey()
    }

    fun save(value: String, account: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray())
        prefs.edit().putString(account, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    fun token(account: String): String? {
        val sealed = prefs.getString(account, null)?.let { Base64.decode(it, Base64.NO_WRAP) } ?: return null
        return runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, 12)) }
            String(cipher.doFinal(sealed, 12, sealed.size - 12))
        }.getOrNull()
    }

    fun delete(account: String) = prefs.edit().remove(account).apply()
}
