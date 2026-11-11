package com.james.easysave

internal class HoldToOpen(private val durationMs: Long = 3000L) {
    private var startedAt: Long? = null
    private var triggered = false

    fun start(now: Long) {
        startedAt = now
        triggered = false
    }

    fun cancel() {
        startedAt = null
    }

    fun progress(now: Long): Float {
        val start = startedAt ?: return 0f
        return ((now - start).coerceAtLeast(0L).toFloat() / durationMs).coerceIn(0f, 1f)
    }

    fun takeTrigger(now: Long): Boolean {
        if (triggered || startedAt == null || progress(now) < 1f) return false
        triggered = true
        return true
    }
}
