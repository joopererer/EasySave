package com.james.easysave.transfer

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

class CookieRestartPolicyTest {

    private lateinit var tempDir: File

    @Before
    fun setUp() {
        tempDir = File("build/tmp/p04b_cookie_${System.nanoTime()}").apply { mkdirs() }
        TransferParamsRegistry.clear()
    }

    @After
    fun tearDown() {
        TransferParamsRegistry.clear()
        tempDir.deleteRecursively()
    }

    @Test
    fun testCookieNotPersistedToMeta_andRestartTriggersUrlExpiredReresolve() = runBlocking {
        val jobId = "tiktok_cookie_job_1"
        val secretCookie = "sessionid=super_secret_cookie_xyz_999"

        val job = TransferJob(
            jobId = jobId,
            direction = Direction.DOWNLOAD,
            category = JobCategory.LARGE_FILE,
            batchId = "bg-tiktok-1",
        )

        val metaFile = File(tempDir, "$jobId.meta")
        val meta = TransferMeta(
            url = "https://v16.tiktokcdn.com/video.mp4",
            mime = "video/mp4",
            policyKey = "tiktok",
            requiresCookie = true,
        )
        TransferMeta.write(metaFile, meta)

        // Verify cookie is never written to .meta
        val metaText = metaFile.readText()
        assertFalse(metaText.contains(secretCookie))
        assertTrue(metaText.contains("\"requiresCookie\":true"))

        // Simulate process restart: in-memory params cleared
        TransferParamsRegistry.clear()

        val worker = HttpWorker(transfersDir = tempDir)
        val result = worker.execute(job) { _, _ -> }
        assertTrue(result is WorkerResult.UrlExpired)
        assertEquals(401, (result as WorkerResult.UrlExpired).code)
    }
}

