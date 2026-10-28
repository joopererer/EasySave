package com.james.easysave

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.Toast

/**
 * Share-sheet entry ("EasySave 后台下载"). Transparent and no-animation: it
 * forwards the shared text to HostService and finishes, so the user stays in
 * the original app. Coexists with the existing MainActivity share entry (which
 * opens the full app); this one downloads in the background.
 */
class ShareToBackgroundActivity : Activity() {
    companion object {
        private const val TAG = "V16SHARE"
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

        val text = intent?.getStringExtra(Intent.EXTRA_TEXT)
            ?: intent?.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        // Never log the shared text itself (it can contain a link with
        // tokens) — only its length and the host of the first URL.
        Log.i(TAG, "share text=${LogSanitizer.summarize(text)}")

        // Reject unsupported hosts before starting the background engine.
        // Dart handles canonicalization and resolves platform short links.
        if (text.isNullOrBlank() || !SupportedLinks.containsSupportedUrl(text)) {
            Toast.makeText(this, "没有可解析的链接", Toast.LENGTH_SHORT).show()
        } else {
            HostService.submitText(this, text, "all", "background")
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
