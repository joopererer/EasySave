package com.james.easysave

import kotlin.math.roundToInt

internal data class BubbleBounds(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    fun maxX(size: Int) = (right - size).coerceAtLeast(left)
    fun maxY(size: Int) = (bottom - size).coerceAtLeast(top)
    fun snapX(leftSide: Boolean, size: Int) = if (leftSide) left else maxX(size)
    fun fraction(y: Int, size: Int): Float {
        val range = maxY(size) - top
        return if (range == 0) 0f else ((y - top).toFloat() / range).coerceIn(0f, 1f)
    }

    fun yAt(fraction: Float, size: Int) =
        top + ((maxY(size) - top) * fraction.coerceIn(0f, 1f)).roundToInt()
}

internal fun resnappedPosition(
    previous: BubbleBounds, current: BubbleBounds, y: Int, size: Int,
    leftSide: Boolean, rotationFraction: Float?,
): Pair<Int, Int>? {
    if (previous == current) return null
    val fraction = rotationFraction ?: previous.fraction(y, size)
    return current.snapX(leftSide, size) to current.yAt(fraction, size)
}
