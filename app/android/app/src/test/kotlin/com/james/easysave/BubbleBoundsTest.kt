package com.james.easysave

import org.junit.Assert.assertEquals
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
}
