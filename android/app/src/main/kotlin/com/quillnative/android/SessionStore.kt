package com.quillnative.android

import android.content.Context

data class Session(val site: String, val micropub: String, val token: String)

/**
 * Keeps the signed-in site. Scaffold only: the token sits in app-private preferences.
 * Before release, wrap it with an Android Keystore key, like the iOS app's Keychain storage.
 */
class SessionStore(context: Context) {
    private val prefs = context.getSharedPreferences("session", Context.MODE_PRIVATE)

    fun load(): Session? {
        val site = prefs.getString("site", null) ?: return null
        val micropub = prefs.getString("micropub", null) ?: return null
        val token = prefs.getString("token", null) ?: return null
        return Session(site, micropub, token)
    }

    fun save(session: Session) {
        prefs.edit().putString("site", session.site).putString("micropub", session.micropub).putString("token", session.token).apply()
    }

    fun clear() = prefs.edit().clear().apply()
}
