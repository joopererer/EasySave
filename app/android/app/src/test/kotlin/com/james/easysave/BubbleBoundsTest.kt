package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BubbleBoundsTest {
    @Test fun rotatedBoundsPreserveSideAndVerticalFraction() {
        val portrait = BubbleBounds(0, 80, 1080, 2300)
        val landscape = BubbleBounds(110, 0, 2300, 1020)
        val y = portrait.yAt(0.6f, 100)
        val rotated = landscape.yAt(portrait.fraction(y, 100), 100)
        assertEquals(552, rotated)
        assertEquals(110, landscape.snapX(true, 100))
        assertEquals(2200, landscape.snapX(false, 100))
    }

    @Test fun cutoutInsetsAffectOnlyTheirOwnEdge() {
        val bounds = BubbleBounds(80, 0, 2400, 1080)
        assertEquals(80, bounds.snapX(true, 100))
        assertEquals(2300, bounds.snapX(false, 100))
    }

    @Test fun waitsForChangedBoundsAndResnapsAgainWhenInsetsChange() {
        val portrait = BubbleBounds(0, 80, 1080, 2300)
        val landscapeOldInsets = BubbleBounds(80, 0, 2200, 1080)
        val landscapeNewInsets = BubbleBounds(80, 0, 2300, 1080)
        val fraction = 0.6f
        assertNull(resnappedPosition(portrait, portrait, 500, 100, false, fraction))
        val first = resnappedPosition(portrait, landscapeOldInsets, 500, 100, false, fraction)!!
        assertEquals(2100, first.first)
        val next = resnappedPosition(landscapeOldInsets, landscapeNewInsets, first.second, 100, false, null)!!
        assertEquals(2200, next.first)
        assertEquals(first.second, next.second)
    }
}
