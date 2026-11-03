package com.james.easysave

internal class PreviewFrameGate {
    private var started = false
    private var shown = false

    fun started() {
        started = true
    }

    fun firstFrame(): Boolean {
        if (!started || shown) return false
        shown = true
        return true
    }
}
