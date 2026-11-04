package com.james.easysave

/** Owns exactly one resource. Invalidates callbacks before releasing it. */
internal class PreviewSessions<T : Any>(private val release: (T) -> Unit) {
    private var generation = 0L
    private var current: T? = null
    fun begin(factory: () -> T): Pair<Long, T> {
        close()
        val value = factory()
        current = value
        return generation to value
    }
    fun accepts(token: Long, value: T) = token == generation && current === value
    fun close() {
        generation++
        val previous = current
        current = null
        if (previous != null) release(previous)
    }
}

internal data class PreviewBounds(val width: Int, val height: Int)
internal fun stillLetterbox(imageWidth: Int, imageHeight: Int, width: Int, height: Int): PreviewBounds? {
    if (minOf(imageWidth, imageHeight, width, height) <= 0) return null
    val scale = minOf(width.toDouble() / imageWidth, height.toDouble() / imageHeight)
    return PreviewBounds((imageWidth * scale).toInt(), (imageHeight * scale).toInt())
}

internal fun holdCountdown(progress: Float): Int =
    kotlin.math.ceil(3.0 * (1.0 - progress.coerceIn(0f, 1f))).toInt().coerceIn(1, 3)

internal fun parsingDotOffsets(timeMs: Long, animate: Boolean): List<Float> =
    (0..2).map { if (animate) kotlin.math.sin(timeMs / 180.0 - it * 0.9).toFloat() else 0f }

/** A different selected codec alone is not proof of fallback. */
internal class DecoderFallbackTrace {
    private val failedInitializations = mutableSetOf<String>()
    private var previous: String? = null
    private var runtimeFailure = false
    private var occurred = false
    @Synchronized fun initializationFailed(name: String) { failedInitializations.add(name) }
    @Synchronized fun codecFailed() { runtimeFailure = true }
    @Synchronized fun initialized(name: String): Boolean {
        occurred = occurred || failedInitializations.any { it != name } ||
            (runtimeFailure && previous != null && previous != name)
        previous = name
        runtimeFailure = false
        failedInitializations.clear()
        return occurred
    }
}
