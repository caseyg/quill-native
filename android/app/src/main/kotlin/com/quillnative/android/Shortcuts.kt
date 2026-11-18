package com.quillnative.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.quillnative.core.Draft

/** Launcher shortcuts for the newest drafts, the counterpart of the iOS Open Draft shortcut. Static ones live in res/xml/shortcuts.xml. */
object Shortcuts {
    private var context: Context? = null

    fun attach(context: Context) { this.context = context.applicationContext }

    fun update(@Suppress("UNUSED_PARAMETER") storage: Storage, drafts: List<Draft>) {
        val context = context ?: return
        runCatching {
            val limit = maxOf(0, ShortcutManagerCompat.getMaxShortcutCountPerActivity(context) - 3).coerceAtMost(2)
            val items = drafts.take(limit).mapIndexed { index, draft ->
                ShortcutInfoCompat.Builder(context, "draft-${draft.id}")
                    .setShortLabel(draft.displayTitle.take(24))
                    .setLongLabel(draft.displayTitle.take(48))
                    .setIcon(IconCompat.createWithResource(context, R.drawable.ic_shortcut_draft))
                    .setIntent(Intent(Intent.ACTION_VIEW, Uri.parse("quill-native://draft?id=${draft.id}"), context, MainActivity::class.java))
                    .setRank(10 + index)
                    .build()
            }
            ShortcutManagerCompat.setDynamicShortcuts(context, items)
        }
    }
}
