package com.james.easysave.transfer

import android.content.Context
import com.james.easysave.provenance.ProvenanceEmbedder
import com.james.easysave.provenance.ProvenanceRecord
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.nio.charset.StandardCharsets

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class TransferFinalizerTest {

    private lateinit var context: Context
    private lateinit var tempDir: File
    private lateinit var transfersDir: File
    private lateinit var store: TransferStore
    private lateinit var publisher: FakeMediaPublisher
    private lateinit var finalizer: TransferFinalizer

    private fun findTestVector(name: String): File {
        val candidates = listOf(
            File("../../docs/provenance-spec/test-vectors/$name"),
            File("../../../docs/provenance-spec/test-vectors/$name"),
            File("../docs/provenance-spec/test-vectors/$name"),
            File("docs/provenance-spec/test-vectors/$name"),
            File("../../../../docs/provenance-spec/test-vectors/$name"),
        )
        return candidates.firstOrNull { it.exists() }
            ?: error("Test vector not found: $name. Checked: ${candidates.map { it.canonicalPath }}")
    }

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        tempDir = File.createTempFile("finalizer_test_", "").apply {
            delete()
            mkdirs()
        }
        transfersDir = File(tempDir, "transfers").apply { mkdirs() }
        store = TransferStore(context, "transfer_test_${System.currentTimeMillis()}.db")
        publisher = FakeMediaPublisher()
        finalizer = TransferFinalizer(transfersDir, store, publisher)
    }

    private fun <T> runOnBg(block: () -> T): T {
        var result: Result<T>? = null
        val t = kotlin.concurrent.thread(start = true) {
            result = runCatching { block() }
        }
        t.join()
        return result!!.getOrThrow()
    }

    @Test
    fun testLengthMismatch_transitionsToFailed() {
        val partFile = File(transfersDir, "job1.part").apply {
            writeBytes(byteArrayOf(1, 2, 3, 4, 5))
        }
        val job = TransferJob(jobId = "job1", totalBytes = 100L)
        store.insertOrReplace(job)
        val meta = TransferMeta(url = "https://example.com/test.jpg", total = 100L, mime = "image/jpeg")

        val outcome = runOnBg { finalizer.execute(job, meta, partFile) }
        assertTrue(outcome is FinalizeOutcome.Failed)
        assertEquals("length_mismatch", (outcome as FinalizeOutcome.Failed).reason)
    }

    @Test
    fun testSniffMismatch_transitionsToFailed() {
        // Expected image/jpeg, but file content is plain text / HTML
        val partFile = File(transfersDir, "job2.part").apply {
            writeText("<html><body>Error 404</body></html>")
        }
        val job = TransferJob(jobId = "job2", totalBytes = partFile.length())
        store.insertOrReplace(job)
        val meta = TransferMeta(url = "https://example.com/test.jpg", total = partFile.length(), mime = "image/jpeg")

        val outcome = runOnBg { finalizer.execute(job, meta, partFile) }
        assertTrue(outcome is FinalizeOutcome.Failed)
        assertEquals("sniff_mismatch", (outcome as FinalizeOutcome.Failed).reason)
    }

    @Test
    fun testUnsupportedFormat_skipsProvenanceEmbeddingAndPublishes() {
        // GIF file header
        val gifBytes = byteArrayOf('G'.code.toByte(), 'I'.code.toByte(), 'F'.code.toByte(), '8'.code.toByte(), '9'.code.toByte(), 'a'.code.toByte(), 0, 0, 0, 0)
        val partFile = File(transfersDir, "job_gif.part").apply {
            writeBytes(gifBytes)
        }
        val job = TransferJob(jobId = "job_gif", totalBytes = gifBytes.size.toLong())
        store.insertOrReplace(job)
        val meta = TransferMeta(
            url = "https://example.com/anim.gif",
            total = gifBytes.size.toLong(),
            mime = "image/gif",
            provenance = mapOf("assetId" to "test-asset-1", "platform" to "tiktok")
        )

        val outcome = runOnBg { finalizer.execute(job, meta, partFile) }
        assertTrue(outcome is FinalizeOutcome.Success)
        val success = outcome as FinalizeOutcome.Success
        assertEquals("skipped_unsupported", success.provenanceStatus)
        assertEquals(1, publisher.entries.size)
        val published = publisher.entries.values.first()
        assertEquals(false, published.isPending)
        assertArrayEquals(gifBytes, published.data)

        val storedJob = store.getJob("job_gif")
        assertNotNull(storedJob)
        assertEquals("skipped_unsupported", storedJob?.provenanceStatus)
        assertEquals(true, storedJob?.historyPending)
    }

    @Test
    fun testByteForByteConsistencyWithDirectProvenanceEmbedder() {
        val testJpeg = findTestVector("no-metadata.jpg")
        val partFile = File(transfersDir, "job_canon.part").apply {
            writeBytes(testJpeg.readBytes())
        }
        val recordMap = mapOf(
            "schema" to "0.1",
            "assetId" to "11111111-2222-3333-4444-555555555555",
            "capturedAt" to "2026-11-24T20:00:00Z",
            "capturedBy" to "EasySave/1.13.0",
            "metadataDate" to "2026-11-24T20:00:00Z",
            "source" to mapOf(
                "url" to "https://www.tiktok.com/@user/video/12345",
                "platform" to "tiktok",
                "id" to "12345"
            ),
            "title" to "Test Title"
        )
        val job = TransferJob(jobId = "job_canon", totalBytes = testJpeg.length())
        store.insertOrReplace(job)
        val meta = TransferMeta(
            url = "https://example.com/test.jpg",
            total = testJpeg.length(),
            mime = "image/jpeg",
            provenance = recordMap
        )

        // Direct embed output
        val directOutput = File(tempDir, "direct_output.jpg")
        ProvenanceEmbedder.embed(testJpeg, directOutput, ProvenanceRecord.fromMap(recordMap))
        val directBytes = directOutput.readBytes()

        // Finalizer output
        val outcome = runOnBg { finalizer.execute(job, meta, partFile) }
        assertTrue(outcome is FinalizeOutcome.Success)
        val success = outcome as FinalizeOutcome.Success
        assertEquals("embedded", success.provenanceStatus)
        assertEquals(true, success.readbackMatch)

        assertEquals(1, publisher.entries.size)
        val publishedEntry = publisher.entries.values.first()
        assertEquals(false, publishedEntry.isPending)
        assertArrayEquals(directBytes, publishedEntry.data)
    }

    @Test
    fun testKillRecovery_atEmbedded_publishesSingleFile() {
        val testJpeg = findTestVector("no-metadata.jpg")
        val partFile = File(transfersDir, "job_rec1.part").apply {
            writeBytes(testJpeg.readBytes())
        }
        val recordMap = mapOf(
            "schema" to "0.1",
            "assetId" to "aaaa1111-2222-3333-4444-555555555555",
            "capturedAt" to "2026-11-24T20:00:00Z",
            "capturedBy" to "EasySave/1.13.0",
            "metadataDate" to "2026-11-24T20:00:00Z",
            "source" to mapOf(
                "url" to "https://www.tiktok.com/@user/video/111",
                "platform" to "tiktok",
                "id" to "111"
            )
        )
        val job = TransferJob(
            jobId = "job_rec1",
            totalBytes = testJpeg.length(),
            finalizeStep = "embedded",
            provenanceStatus = "embedded"
        )
        store.insertOrReplace(job)
        val meta = TransferMeta(url = "https://example.com/1.jpg", total = testJpeg.length(), mime = "image/jpeg", provenance = recordMap)

        // Pre-create .final as if embed finished before kill
        val finalFile = File(transfersDir, "job_rec1.final")
        ProvenanceEmbedder.embed(testJpeg, finalFile, ProvenanceRecord.fromMap(recordMap))

        val outcome = runOnBg { finalizer.execute(job, meta, partFile) }
        assertTrue(outcome is FinalizeOutcome.Success)
        assertEquals(1, publisher.entries.size)
        val entry = publisher.entries.values.first()
        assertEquals(false, entry.isPending)
        assertNotNull(entry.data)
    }

    @Test
    fun testKillRecovery_atInserted_deletesPendingAndRePublishesSingleCleanFile() {
        val testJpeg = findTestVector("no-metadata.jpg")
        val partFile = File(transfersDir, "job_rec2.part").apply {
            writeBytes(testJpeg.readBytes())
        }
        val recordMap = mapOf(
            "schema" to "0.1",
            "assetId" to "bbbb1111-2222-3333-4444-555555555555",
            "capturedAt" to "2026-11-24T20:00:00Z",
            "capturedBy" to "EasySave/1.13.0",
            "metadataDate" to "2026-11-24T20:00:00Z",
            "source" to mapOf(
                "url" to "https://www.tiktok.com/@user/video/222",
                "platform" to "tiktok",
                "id" to "222"
            )
        )
        // Simulate half-written pending entry in MediaStore before kill
        val pendingMediaId = "999"
        publisher.entries[pendingMediaId] = FakeMediaPublisher.Entry(
            mediaId = pendingMediaId,
            relativePath = "Pictures/EasySave/",
            displayName = "job_rec2_1.jpg",
            mime = "image/jpeg",
            data = byteArrayOf(1, 2, 3), // half-written
            isPending = true
        )

        val job = TransferJob(
            jobId = "job_rec2",
            totalBytes = testJpeg.length(),
            finalizeStep = "inserted:$pendingMediaId",
            mediaId = pendingMediaId
        )
        store.insertOrReplace(job)
        val meta = TransferMeta(url = "https://example.com/2.jpg", total = testJpeg.length(), mime = "image/jpeg", provenance = recordMap)

        val outcome = runOnBg { finalizer.execute(job, meta, partFile) }
        assertTrue(outcome is FinalizeOutcome.Success)
        // Verify: old pending entry 999 must be deleted, exactly 1 published file in publisher
        assertEquals(1, publisher.entries.size)
        val remaining = publisher.entries.values.first()
        assertEquals(false, remaining.isPending)
        assertTrue("New mediaId must not be the old pending 999", remaining.mediaId != pendingMediaId)
    }

    @Test
    fun testKillRecovery_atPublished_doesNotInsertSecondFile() {
        val testJpeg = findTestVector("no-metadata.jpg")
        val recordMap = mapOf(
            "schema" to "0.1",
            "assetId" to "cccc1111-2222-3333-4444-555555555555",
            "capturedAt" to "2026-11-24T20:00:00Z",
            "capturedBy" to "EasySave/1.13.0",
            "metadataDate" to "2026-11-24T20:00:00Z",
            "source" to mapOf(
                "url" to "https://www.tiktok.com/@user/video/333",
                "platform" to "tiktok",
                "id" to "333"
            )
        )
        // Generate valid embedded jpeg for the published entry
        val tempOut = File(tempDir, "temp_embed.jpg")
        ProvenanceEmbedder.embed(testJpeg, tempOut, ProvenanceRecord.fromMap(recordMap))
        val embeddedBytes = tempOut.readBytes()

        val publishedMediaId = "888"
        publisher.entries[publishedMediaId] = FakeMediaPublisher.Entry(
            mediaId = publishedMediaId,
            relativePath = "Pictures/EasySave/",
            displayName = "job_rec3_1.jpg",
            mime = "image/jpeg",
            data = embeddedBytes,
            isPending = false
        )

        val partFile = File(transfersDir, "job_rec3.part").apply {
            writeBytes(testJpeg.readBytes())
        }
        val job = TransferJob(
            jobId = "job_rec3",
            totalBytes = testJpeg.length(),
            finalizeStep = "published",
            mediaId = publishedMediaId,
            title = "job_rec3_1.jpg",
            provenanceStatus = "embedded"
        )
        store.insertOrReplace(job)
        val meta = TransferMeta(url = "https://example.com/3.jpg", total = testJpeg.length(), mime = "image/jpeg", provenance = recordMap)

        val outcome = runOnBg { finalizer.execute(job, meta, partFile) }
        assertTrue(outcome is FinalizeOutcome.Success)
        // Must NOT insert second entry
        assertEquals(1, publisher.entries.size)
        assertEquals(publishedMediaId, publisher.entries.keys.first())
    }

    @Test
    fun testMainThreadAssertion_throwsWhenRunOnMainThread() {
        val testJpeg = findTestVector("no-metadata.jpg")
        val partFile = File(transfersDir, "job_main.part").apply {
            writeBytes(testJpeg.readBytes())
        }
        val job = TransferJob(jobId = "job_main", totalBytes = testJpeg.length())
        val meta = TransferMeta(url = "https://example.com/main.jpg", total = testJpeg.length(), mime = "image/jpeg")

        // Robolectric runs tests on the Android main looper by default!
        var caught: IllegalStateException? = null
        try {
            finalizer.execute(job, meta, partFile)
        } catch (e: IllegalStateException) {
            caught = e
        }
        assertNotNull("Must throw IllegalStateException on main thread", caught)
        assertTrue(caught!!.message!!.contains("background thread"))
    }
}

