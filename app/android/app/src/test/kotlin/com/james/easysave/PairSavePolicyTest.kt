package com.james.easysave

import org.junit.Assert.*
import org.junit.Test

class PairSavePolicyTest {
    @Test fun finalPairUsesCleanIdentityName() {
        val name = PairSavePolicy.mediaName("7674898126922140959_1.jpg")
        assertEquals("7674898126922140959_1.jpg", name)
        assertEquals("7674898126922140959_1.jpg.xmp", ProvenancePairWriter.sidecarName(name))
    }
    @Test fun rejectsInvalidNamesAndUniqueSuffixes() {
        for (name in listOf("", "../a.jpg", "a", ".jpg", "a.")) {
            assertTrue(runCatching { PairSavePolicy.mediaName(name) }.isFailure)
        }
        assertTrue(runCatching { PairSavePolicy.mediaName("123_1_550e8400-e29b-41d4-a716-446655440000.jpg") }.isFailure)
    }
    @Test fun binarySidecarMimeAvoidsRdfExtensionMapping() {
        assertEquals("application/octet-stream", PairSavePolicy.SIDECAR_MIME)
        assertEquals("Download/EasySave/", C2paStoragePolicy.RELATIVE_PATH)
    }
    @Test fun errorKeepsStepClassAndUsefulMessage() {
        assertEquals("写入图片: IllegalStateException: disk full",
            PairSavePolicy.errorMessage("写入图片", IllegalStateException("disk full")))
    }
    @Test fun errorRedactsUrlQueriesFragmentsAndCookies() {
        val result = PairSavePolicy.errorMessage("回读校验", IllegalArgumentException(
            "failed https://example.invalid/a?token=SECRET#SECRET\nCookie: session=PRIVATE"))
        assertTrue(result.contains("IllegalArgumentException"))
        assertFalse(result.contains("SECRET"))
        assertFalse(result.contains("PRIVATE"))
        assertFalse(result.contains("\n"))
    }
}
