package com.james.easysave

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.util.Log

/**
 * Entry point for the text-selection menu ("EasySave 下载"). Transparent and
 * no-animation: it forwards the selected text to HostService (our app is in
 * the foreground here, so starting the foreground service is allowed) and
 * finishes immediately. This entry does not touch the clipboard.
 */
class ProcessTextActivity : Activity() {
    companion object {
        private const val TAG = "V16PROC"
    }

    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        }
    }

    override fun onResume() {
        super.onResume()
        if (handled) return
        handled = true

        val text = intent?.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        Log.i(TAG, "processText=${text?.take(120) ?: "<null>"}")
        if (!text.isNullOrBlank()) {
            HostService.submitText(this, text, "all", "background")
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
