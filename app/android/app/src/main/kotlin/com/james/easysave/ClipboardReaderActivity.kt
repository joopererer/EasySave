package com.james.easysave

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.Toast

/**
 * v1.6 validation: a transparent, no-animation Activity that reads the
 * clipboard in onCreate and finishes immediately. Used to check that the
 * clipboard can be read on Android 10+ without pushing the underlying app to
 * the background or flashing a visible window.
 */
class ClipboardReaderActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        }
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = cm.primaryClip
        val text: String? =
            if (clip != null && clip.itemCount > 0) clip.getItemAt(0).coerceToText(this)?.toString() else null
        Log.i("V16VAL", "CLIPBOARD=${text ?: "<null>"}")
        Toast.makeText(this, "剪贴板: " + (text?.take(60) ?: "空"), Toast.LENGTH_LONG).show()
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
