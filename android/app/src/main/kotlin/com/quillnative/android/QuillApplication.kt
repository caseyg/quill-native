package com.quillnative.android

import android.app.Application
import android.content.Context

class QuillApplication : Application() {
    val store: AppStore by lazy { AppStore(this) }

    override fun onCreate() {
        super.onCreate()
        Shortcuts.attach(this)
    }
}

val Context.store: AppStore get() = (applicationContext as QuillApplication).store
