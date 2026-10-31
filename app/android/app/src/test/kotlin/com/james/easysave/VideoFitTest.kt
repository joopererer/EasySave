package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bubble's select panel played videos through a TextureView that stretched
 * its surface to the view bounds. These checks pin the letterbox factors: a
 * 9:16 clip must keep its shape inside any view, the rest of the area staying
 * black.
 */
class VideoFitTest {
    @Test
    fun portraitClipInATallerViewScalesToFullWidth() {
        // 1080x1920 video inside a 1080x2400 view: width-limited.
        val fit = videoFitScale(1080, 1920, 1080, 2400)
        assertNotNull(fit)
        assertEquals(1f, fit!!.scaleX, 1e-4f)
        // The stretched content is scaled back to 1920/2400 of the view height,
        // so the rendered box measures 1080 x 1920 (source ratio, full width).
        assertEquals(1920f / 2400f, fit.scaleY, 1e-4f)
        assertEquals(1080f, 1080f * fit.scaleX, 1e-2f)
        assertEquals(1920f, 2400f * fit.scaleY, 1e-2f)
    }

    @Test
    fun landscapeClipInAPortraitViewIsWidthLimited() {
        val fit = videoFitScale(1920, 1080, 1080, 1920)
        assertNotNull(fit)
        assertEquals(1f, fit!!.scaleX, 1e-4f)
        // Rendered box fills the view width and keeps the source ratio; the
        // remainder of the height stays black.
        val renderedWidth = 1080f * fit.scaleX
        val renderedHeight = 1920f * fit.scaleY
        assertEquals(1080f, renderedWidth, 1e-2f)
        assertEquals(1920f / 1080f, renderedWidth / renderedHeight, 1e-3f)
        assertTrue(renderedHeight < 1920f)
    }

    @Test
    fun matchingRatioFillsTheViewExactly() {
        val fit = videoFitScale(1080, 1920, 540, 960)
        assertNotNull(fit)
        assertEquals(1f, fit!!.scaleX, 1e-4f)
        assertEquals(1f, fit.scaleY, 1e-4f)
    }

    @Test
    fun invalidSizesProduceNoTransform() {
        assertNull(videoFitScale(0, 1920, 1080, 1920))
        assertNull(videoFitScale(1080, 1920, 0, 1920))
        assertNull(videoFitScale(-1, 1920, 1080, 1920))
        assertNull(videoFitScale(1080, 1920, 1080, 0))
    }

    @Test
    fun nothingIsEverCropped() {
        val views = listOf(1080 to 1920, 1920 to 1080, 720 to 720, 1080 to 2400)
        val clips = listOf(1080 to 1920, 1920 to 1080, 640 to 480, 480 to 640)
        for ((vw, vh) in views) {
            for ((w, h) in clips) {
                val fit = videoFitScale(w, h, vw, vh)
                assertNotNull(fit)
                // One axis fills the view exactly and the other is shrunk, so
                // nothing is ever enlarged or cropped out of the visible area.
                val fillsOneAxis =
                    Math.abs(fit!!.scaleX - 1f) < 1e-4f || Math.abs(fit.scaleY - 1f) < 1e-4f
                assertTrue("$w x $h in $vw x $vh", fillsOneAxis)
                assertTrue("scaleX ${fit.scaleX}", fit.scaleX <= 1f + 1e-4f)
                assertTrue("scaleY ${fit.scaleY}", fit.scaleY <= 1f + 1e-4f)
            }
        }
    }
}
