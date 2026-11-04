package com.james.easysave

import org.junit.Assert.*
import org.junit.Test

class PreviewSessionsTest {
    @Test fun errorReleaseThenPreviewCreatesANewInstance() {
        val released = mutableListOf<Any>()
        val sessions = PreviewSessions<Any> { released.add(it) }
        val first = sessions.begin { Any() }
        sessions.close()
        val second = sessions.begin { Any() }
        assertNotSame(first.second, second.second)
        assertEquals(listOf(first.second), released)
        assertFalse(sessions.accepts(first.first, first.second))
        assertTrue(sessions.accepts(second.first, second.second))
    }
    @Test fun replacedAndClosedSessionsRejectEveryStaleCallback() {
        val sessions = PreviewSessions<Any> {}
        val old = sessions.begin { Any() }
        val fresh = sessions.begin { Any() }
        assertFalse(sessions.accepts(old.first, old.second))
        assertFalse(sessions.accepts(fresh.first, old.second))
        sessions.close()
        assertFalse(sessions.accepts(fresh.first, fresh.second))
    }
    @Test fun posterUsesItsOwnAspectRatioAfterLandscapeVideo() {
        assertEquals(PreviewBounds(300, 600), stillLetterbox(600, 1200, 800, 600))
        assertEquals(PreviewBounds(800, 400), stillLetterbox(1200, 600, 800, 600))
        assertNull(stillLetterbox(0, 1200, 800, 600))
    }
    @Test fun holdShowsThreeTwoOne() {
        assertEquals(3, holdCountdown(0f))
        assertEquals(2, holdCountdown(0.34f))
        assertEquals(1, holdCountdown(0.67f))
    }
    @Test fun reduceMotionStopsAllThreeDots() {
        assertEquals(listOf(0f, 0f, 0f), parsingDotOffsets(750L, false))
        assertNotEquals(parsingDotOffsets(750L, true), parsingDotOffsets(1000L, true))
    }
}
