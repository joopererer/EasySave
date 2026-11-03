package com.james.easysave

import android.content.Context
import android.util.Log
import java.io.File

/** Native diagnostics sink shared with Dart's application-support DevLog. */
internal object NativeLog {
    @Volatile private var appContext: Context? = null
    private const val fileName = "v16dl.log"
    private val url = Regex("""https?://[^\s"'<>]+""")
    private val secret = Regex(
        """(?i)(cookie|set-cookie|authorization|token|password|secret|session|sig)\s*[:=]\s*[^\s,;)]+"""
    )

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    fun i(tag: String, message: String) = write(Log.INFO, tag, message)
    fun w(tag: String, message: String, error: Throwable? = null) =
        write(Log.WARN, tag, message, error)
    fun e(tag: String, message: String, error: Throwable? = null) =
        write(Log.ERROR, tag, message, error)

    private fun write(priority: Int, tag: String, message: String, error: Throwable? = null) {
        val safe = url.replace(secret.replace(message) { "${it.value.substringBefore('=')}=<redacted>" }) {
            runCatching {
                val uri = java.net.URI(it.value)
                "${uri.host}${uri.path ?: ""}"
            }.getOrDefault("<url>")
        }
        Log.println(priority, tag, safe)
        val context = appContext ?: return
        runCatching {
            val dir = File(context.filesDir, "app_flutter")
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, fileName)
            file.appendText("[${if (priority >= Log.ERROR) "ERROR" else if (priority >= Log.WARN) "WARN" else "INFO"}] [$tag] $safe\n")
        }
    }
}
