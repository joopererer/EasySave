package com.james.easysave

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewFrameGateTest {
    @Test fun acceptsOnlyTheFirstFrameAfterPlaybackStarts() {
        val gate = PreviewFrameGate()
        assertFalse(gate.firstFrame())
        gate.started()
        assertTrue(gate.firstFrame())
        assertFalse(gate.firstFrame())
    }
}
