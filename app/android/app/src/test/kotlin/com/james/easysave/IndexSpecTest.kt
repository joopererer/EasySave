package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IndexSpecTest {

    @Test
    fun singlesAndRanges() {
        val r = IndexSpec.parse("1,3,5-8", 10)
        assertEquals(listOf(0, 2, 4, 5, 6, 7), r.indices)
        assertFalse(r.outOfRange)
        assertFalse(r.invalid)
    }

    @Test
    fun fullWidthAndChineseSeparators() {
        val r = IndexSpec.parse("１，３、５－７ 9", 10)
        assertEquals(listOf(0, 2, 4, 5, 6, 8), r.indices)
        assertFalse(r.invalid)
    }

    @Test
    fun duplicatesAndReversedRange() {
        val r = IndexSpec.parse("3,3,6-4", 9)
        assertEquals(listOf(2, 3, 4, 5), r.indices)
    }

    @Test
    fun outOfRangeIsClippedAndFlagged() {
        val r = IndexSpec.parse("0,2,8-12", 9)
        assertEquals(listOf(1, 7, 8), r.indices)
        assertTrue(r.outOfRange)
    }

    @Test
    fun invalidTokensAreFlagged() {
        val r = IndexSpec.parse("a,2,3-", 5)
        assertEquals(listOf(1), r.indices)
        assertTrue(r.invalid)
    }

    @Test
    fun emptyInput() {
        val r = IndexSpec.parse("  ", 5)
        assertTrue(r.indices.isEmpty())
        assertFalse(r.invalid)
    }
}
