package com.james.easysave

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast

/**
 * Transparent, no-animation Activity that reads the clipboard and returns it
 * to an in-process caller. Used by the bubble and the Quick Settings tile,
 * which cannot read the clipboard themselves (no focus).
 *
 * Android 10+ only lets a caller with window focus read the clipboard, and an
 * onCreate read returns empty (verified on device), so we read only from
 * onWindowFocusChanged(true). If focus never arrives within [TIMEOUT_MS] we
 * finish and report an empty result.
 */
class ClipboardReaderActivity : Activity() {
    companion object {
        private const val TAG = "V16CLIP"
        private const val TIMEOUT_MS = 500L

        /** Optional extra: toast to show when there is no link in the clipboard. */
        const val EXTRA_EMPTY_MESSAGE = "empty_msg"

        /** Set by the caller right before startActivity; invoked exactly once. */
        var listener: ((String?) -> Unit)? = null

        /** Deliver the result to the pending listener and clear it. */
        fun deliver(text: String?) {
            val cb = listener
            listener = null
            cb?.invoke(text)
        }
    }

    private var done = false
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable {
        if (!done) {
            done = true
            Log.i(TAG, "CLIPBOARD=<timeout: no focus>")
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        }
        handler.postDelayed(timeout, TIMEOUT_MS)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !done) {
            done = true
            handler.removeCallbacks(timeout)
            readAndFinish()
        }
    }

    private fun readAndFinish() {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = cm.primaryClip
        val text: String? =
            if (clip != null && clip.itemCount > 0) clip.getItemAt(0).coerceToText(this)?.toString() else null
        Log.i(TAG, "CLIPBOARD=${text ?: "<null>"}")
        // Shown from this (foreground) activity so it isn't suppressed the way a
        // background toast would be. The authoritative supported-host check
        // runs in Dart; this only guards the obvious "no URL" case.
        val emptyMsg = intent?.getStringExtra(EXTRA_EMPTY_MESSAGE)
        val hasHttp = !text.isNullOrBlank() && text.contains("http", ignoreCase = true)
        if (!hasHttp && !emptyMsg.isNullOrBlank()) {
            Toast.makeText(this, emptyMsg, Toast.LENGTH_SHORT).show()
        }
        deliver(text)
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    override fun onDestroy() {
        handler.removeCallbacks(timeout)
        // If we were killed before delivering, don't leave a dangling callback.
        if (!done) deliver(null)
        super.onDestroy()
    }
}
