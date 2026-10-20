package app.yuyue

import android.app.Application
import app.yuyue.design.Prefs
import app.yuyue.library.Library
import uniffi.yuyue_core.setUiLanguage

/** One core and one library for the whole process. */
class YuyueApp : Application() {
    lateinit var library: Library
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        var t0 = System.nanoTime()
        fun lap(what: String) { if (BuildConfig.DEBUG) android.util.Log.d("yuyue-start", "$what ${(System.nanoTime() - t0) / 1_000_000} ms"); t0 = System.nanoTime() }
        Prefs.init(this)
        app.yuyue.library.Keys.init(this)
        lap("keys")
        L10n.load(this)
        // The core's own words (errors, 常用规则, a chapter's 读/听 line) in the interface's language.
        setUiLanguage(if (L10n.chinese) "zh-Hans" else "en")
        lap("l10n")
        library = Library(this)
        app.yuyue.reader.EInk.checkDevice(library.core)
        lap("library")
    }

    companion object {
        lateinit var instance: YuyueApp
            private set
    }
}
