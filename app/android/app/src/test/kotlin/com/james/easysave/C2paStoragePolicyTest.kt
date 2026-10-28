package com.james.easysave

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class C2paStoragePolicyTest {
    @Test fun exactDirectoryAndMediaOnly() {
        assertEquals("Download/EasySave/", C2paStoragePolicy.RELATIVE_PATH)
        assertTrue(C2paStoragePolicy.isFixedMedia("Download/EasySave/", "image/jpeg"))
        assertFalse(C2paStoragePolicy.isFixedMedia("Pictures/EasySave/", "image/jpeg"))
        assertFalse(C2paStoragePolicy.isFixedMedia("Download/EasySave/sub/", "image/jpeg"))
        assertFalse(C2paStoragePolicy.isFixedMedia("Download/EasySave/", "application/json"))
        assertFalse(C2paStoragePolicy.isFixedMedia("Download/EasySave/", "application/rdf+xml"))
        assertEquals("relative_path = ? AND media_type IN (1, 3)", C2paStoragePolicy.MEDIA_SELECTION)
    }
    @Test fun approvedMediaDeletionRemovesSidecarAndCancellationKeepsBoth() {
        val directory = Files.createTempDirectory("pair-delete-").toFile()
        try {
            val image = directory.resolve("post.jpg").apply { writeText("synthetic JPEG") }
            val sidecar = directory.resolve("post.jpg.xmp").apply { writeText("synthetic XMP") }
            assertFalse(C2paStoragePolicy.finishDelete(false, listOf(sidecar)) { it.delete() })
            assertTrue(image.exists() && sidecar.exists())
            // RESULT_OK is delivered after MediaStore has removed the image.
            image.delete()
            assertTrue(C2paStoragePolicy.finishDelete(true, listOf(sidecar)) { check(it.delete()) })
            assertFalse(image.exists() || sidecar.exists())
        } finally { directory.deleteRecursively() }
    }
    @Test fun sidecarFailureIsNotReportedAsSuccessfulDeletion() {
        assertTrue(runCatching {
            C2paStoragePolicy.finishDelete(true, listOf("sidecar")) { error("cannot delete") }
        }.isFailure)
    }
}
