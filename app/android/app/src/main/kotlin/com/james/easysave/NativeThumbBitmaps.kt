package com.james.easysave

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import java.util.concurrent.Executors

internal object NativeThumbBitmaps {
    private var memory: ThumbnailMemory<Bitmap>? = null
    val decoders = Executors.newFixedThreadPool(2)
    val legacyNetwork = Executors.newFixedThreadPool(4)
    @Synchronized fun configure(context: Context) {
        if (memory != null) return
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val budget = (manager.memoryClass.toLong() * 1024 * 1024 / 16).coerceIn(2L * 1024 * 1024, 32L * 1024 * 1024)
        memory = ThumbnailMemory(budget, { it.allocationByteCount.toLong() })
    }
    fun get(key: String?) = key?.let { memory?.get(it) }
    fun put(key: String?, bitmap: Bitmap, expires: Long) { if (key != null) memory?.put(key, bitmap, expires) }
    fun remove(key: String) { memory?.removePrefix("$key:") }
}
