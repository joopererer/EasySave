package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Rules the album import uses for a saved video's MediaStore row.
 *
 * The retriever and the MediaStore query need a device (and a real provider),
 * so the table below is what is verified here; the production helpers are used
 * directly, never a stand-in.
 */
class MediaMetadataProbeTest {
    @Test
    fun `a video whose duration stayed unset needs a rescan`() {
        assertTrue(MediaMetadataProbe.needsRescan(null, true))
        assertTrue(MediaMetadataProbe.needsRescan(0L, true))
    }

    @Test
    fun `a video with a duration and every still need no rescan`() {
        assertFalse(MediaMetadataProbe.needsRescan(12_000L, true))
        assertFalse(MediaMetadataProbe.needsRescan(null, false))
        assertFalse(MediaMetadataProbe.needsRescan(0L, false))
    }

    @Test
    fun `retriever text becomes duration and pixel size`() {
        val meta = MediaMetadataProbe.metaOf("12000", "720", "1280")
        assertEquals(12_000L, meta?.durationMs)
        assertEquals(720, meta?.width)
        assertEquals(1280, meta?.height)
    }

    @Test
    fun `unusable retriever answers yield no metadata`() {
        assertNull(MediaMetadataProbe.metaOf(null, "720", "1280"))
        assertNull(MediaMetadataProbe.metaOf("", "720", "1280"))
        assertNull(MediaMetadataProbe.metaOf("0", "720", "1280"))
        assertNull(MediaMetadataProbe.metaOf("not-a-number", "720", "1280"))
    }

    @Test
    fun `missing pixel size falls back to zero`() {
        val meta = MediaMetadataProbe.metaOf("12000", null, "1280")
        assertEquals(0, meta?.width)
        assertEquals(1280, meta?.height)
    }
}
