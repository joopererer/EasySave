package com.james.easysave

import org.junit.Assert.*
import org.junit.Test

class ProvenancePairWriterTest {
    @Test fun keepsEntireFilenameIncludingExtension() {
        assertEquals("post_1.jpg.xmp", ProvenancePairWriter.sidecarName("post_1.jpg"))
        assertEquals("post (1).mp4.xmp", ProvenancePairWriter.sidecarName("post (1).mp4"))
    }
    @Test fun refusesPathsAndEmptyNames() {
        for (name in listOf("", "..", "../photo.jpg", "dir/photo.jpg", "dir\\photo.jpg")) {
            assertTrue(name, runCatching { ProvenancePairWriter.sidecarName(name) }.isFailure)
        }
    }
}
