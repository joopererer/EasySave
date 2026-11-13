package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Decision table of the platform decode probe.
 *
 * The decode itself cannot be unit-tested: Robolectric's BitmapFactory shadow
 * answers every input with a fake bitmap, so it says nothing about the real
 * HEIF decoder of an Android 12 device. What is tested here is the mapping the
 * probe applies to a decoder answer, with the production function used
 * directly — no mock stands in for it.
 */
class ImageDecodeProbeTest {
    @Test
    fun `a decoded picture is decodable and reports its real size`() {
        val outcome = ImageDecodeProbe.decide(1536, 2560, 192, 320, ImageDecodeProbe.DECODER_BITMAP_FACTORY)
        assertTrue(outcome.decodable)
        assertEquals(1536, outcome.width)
        assertEquals(2560, outcome.height)
        assertEquals(192, outcome.sampleWidth)
        assertEquals(ImageDecodeProbe.REASON_OK, outcome.reason)
    }

    @Test
    fun `header without pixels is not decodable`() {
        // The alpha-HEIC case: the container declares 1536x2560 and the
        // bitstream still fails, so no sampled bitmap comes back.
        val outcome = ImageDecodeProbe.decide(1536, 2560, 0, 0, ImageDecodeProbe.DECODER_BITMAP_FACTORY)
        assertFalse(outcome.decodable)
        assertEquals(1536, outcome.width)
        assertEquals(ImageDecodeProbe.REASON_DECODE_FAILED, outcome.reason)
    }

    @Test
    fun `no bounds is not decodable`() {
        val outcome = ImageDecodeProbe.decide(0, 0, 0, 0, ImageDecodeProbe.DECODER_BITMAP_FACTORY)
        assertFalse(outcome.decodable)
        assertEquals(ImageDecodeProbe.REASON_NO_BOUNDS, outcome.reason)
    }

    @Test
    fun `a decoder failure keeps the code and is never decodable`() {
        val outcome = ImageDecodeProbe.decide(0, 0, 0, 0, ImageDecodeProbe.DECODER_IMAGE_DECODER, "SecurityException")
        assertFalse(outcome.decodable)
        assertEquals("SecurityException", outcome.reason)
    }

    @Test
    fun `sample size halves until the long side fits the probe target`() {
        assertEquals(1, ImageDecodeProbe.sampleSizeFor(256, 256))
        assertEquals(2, ImageDecodeProbe.sampleSizeFor(512, 512))
        assertEquals(2, ImageDecodeProbe.sampleSizeFor(513, 513))
        assertEquals(8, ImageDecodeProbe.sampleSizeFor(1536, 2560))
        assertEquals(8, ImageDecodeProbe.sampleSizeFor(2560, 1536))
        assertEquals(1, ImageDecodeProbe.sampleSizeFor(0, 0))
        assertEquals(1, ImageDecodeProbe.sampleSizeFor(100, 100, 0))
    }

    @Test
    fun `outcome map keeps only log-safe fields`() {
        val map = ImageDecodeProbe
            .decide(1536, 2560, 192, 320, ImageDecodeProbe.DECODER_IMAGE_DECODER)
            .toMap()
        assertEquals(true, map["decodable"])
        assertEquals(1536, map["width"])
        assertEquals(ImageDecodeProbe.DECODER_IMAGE_DECODER, map["decoder"])
        assertFalse(map.containsKey("path"))
    }
}
