package com.james.easysave

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri

/**
 * Decodes an album asset for the native panel's fullscreen preview.
 *
 * The bytes come straight from MediaStore, so a file the user already saved is
 * shown at its original resolution without a thumbnail placeholder, a network
 * request or a spinner. Returns null when the id no longer resolves; callers
 * then fall back to the network path.
 */
internal object NativeLocalBitmap {
    fun decode(context: Context, uri: Uri, target: Int): Bitmap? {
        val bytes = runCatching {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        }.getOrNull() ?: return null
        if (bytes.isEmpty()) return null
        return runCatching { OrientedBitmap.decode(bytes, target, "saved") }.getOrNull()
    }
}
