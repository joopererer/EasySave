package com.james.easysave.transfer

import android.content.Context
import com.james.easysave.provenance.ProvenanceEmbedder
import com.james.easysave.provenance.ProvenanceReader
import com.james.easysave.provenance.ProvenanceRecord
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.security.MessageDigest

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class TransferFinalizerTest {

    private lateinit var context: Context
    private lateinit var tempDir: File
    private lateinit var transfersDir: File
    private lateinit var store: TransferStore
    private lateinit var publisher: FakeMediaPublisher
    private lateinit var finalizer: TransferFinalizer

    private fun findGoldenRoot(): File {
        val candidates = listOf(
            File("../../../../../spec/fixtures/provenance_golden"),
            File("../../../../spec/fixtures/provenance_golden"),
            File("../../../spec/fixtures/provenance_golden"),
            File("../../spec/fixtures/provenance_golden"),
            File("../spec/fixtures/provenance_golden"),
            File("spec/fixtures/provenance_golden"),
        )
        return candidates.firstOrNull { it.exists() }
            ?: error("Golden root not found. Checked: ${candidates.map { it.canonicalPath }}")
    }

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

    private fun sha256(bytes: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-256")
        return md.digest(bytes).joinToString("") { "%02x".format(it) }
    }

    private fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            var n: Int
            while (input.read(buf).also { n = it } != -1) {
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun JSONObject.toMap(): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        val keys = keys()
        while (keys.hasNext()) {
            val key = keys.next()
            var value = get(key)
            if (value is JSONObject) {
                value = value.toMap()
            } else if (value is JSONArray) {
                value = List(value.length()) { idx ->
                    val v = value.get(idx)
                    if (v is JSONObject) v.toMap() else v
                }
            }
            map[key] = value
        }
        return map
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
        // Expected image/jpeg, but file content is plain text / HTML error page
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
    fun testSniffMismatch_heicImageWithJpegExpected_isAcceptedAndSavedAsHeic() {
        // 模拟小红书：预期 image/jpeg，但 CDN 返回合法 HEIC 图片
        val heicHeader = byteArrayOf(
            0, 0, 0, 24, // 24 bytes box size
            'f'.code.toByte(), 't'.code.toByte(), 'y'.code.toByte(), 'p'.code.toByte(),
            'm'.code.toByte(), 'i'.code.toByte(), 'f'.code.toByte(), '1'.code.toByte(), // mif1 brand
            0, 0, 0, 0,
            'h'.code.toByte(), 'e'.code.toByte(), 'i'.code.toByte(), 'c'.code.toByte(), // heic brand
            0, 0, 0, 0
        )
        val partFile = File(transfersDir, "job_heic.part").apply {
            writeBytes(heicHeader)
        }
        val job = TransferJob(jobId = "job_heic", totalBytes = heicHeader.size.toLong())
        store.insertOrReplace(job)
        val meta = TransferMeta(
            url = "https://sns-img-qc.xhscdn.com/test",
            total = heicHeader.size.toLong(),
            mime = "image/jpeg", // 预期是 jpeg
            provenance = mapOf("assetId" to "test-heic-1", "platform" to "xhs")
        )

        val outcome = runOnBg { finalizer.execute(job, meta, partFile) }
        assertTrue(outcome is FinalizeOutcome.Success)
        val success = outcome as FinalizeOutcome.Success
        assertEquals("skipped_unsupported", success.provenanceStatus)
        assertEquals(1, publisher.entries.size)
        val published = publisher.entries.values.first()
        assertEquals(false, published.isPending)
        assertTrue("DisplayName should end with .heic", published.displayName.endsWith(".heic"))
        assertArrayEquals(heicHeader, published.data)
    }

    @Test
    fun test12GoldenSamplesConsistencyWithFakeMediaPublisher() {
        val goldenRoot = findGoldenRoot()
        assertTrue("Golden root must exist at ${goldenRoot.absolutePath}", goldenRoot.exists())
        val subdirs = goldenRoot.listFiles()?.filter { it.isDirectory }?.sortedBy { it.name } ?: emptyList()
        assertTrue("Must have at least 12 golden samples", subdirs.size >= 12)

        for (dir in subdirs) {
            val inputFile = dir.listFiles()?.firstOrNull { it.name.startsWith("input.") }
                ?: error("Missing input file in ${dir.name}")
            val goldenOutputFile = dir.listFiles()?.firstOrNull { it.name.startsWith("golden_output.") }
                ?: error("Missing golden output file in ${dir.name}")
            val jsonFile = File(dir, "provenance.json")
            assertTrue("Missing provenance.json in ${dir.name}", jsonFile.exists())

            val recordMap = JSONObject(jsonFile.readText()).toMap()
            val goldenSha = sha256(goldenOutputFile)

            // Setup fresh publisher and part file for this sample
            val samplePublisher = FakeMediaPublisher()
            val sampleFinalizer = TransferFinalizer(transfersDir, store, samplePublisher)

            val partFile = File(transfersDir, "sample_${dir.name}.part").apply {
                writeBytes(inputFile.readBytes())
            }

            val mime = when (inputFile.extension.lowercase()) {
                "jpg", "jpeg" -> "image/jpeg"
                "png" -> "image/png"
                "webp" -> "image/webp"
                "mp4", "mov" -> "video/mp4"
                else -> "image/jpeg"
            }

            val job = TransferJob(
                jobId = "sample_${dir.name}",
                totalBytes = inputFile.length()
            )
            store.insertOrReplace(job)
            val meta = TransferMeta(
                url = "https://example.com/${inputFile.name}",
                total = inputFile.length(),
                mime = mime,
                provenance = recordMap
            )

            val outcome = runOnBg { sampleFinalizer.execute(job, meta, partFile) }
            assertTrue("Finalizer outcome must be success for ${dir.name}", outcome is FinalizeOutcome.Success)
            val success = outcome as FinalizeOutcome.Success
            assertEquals("embedded", success.provenanceStatus)
            assertEquals("Readback must match for ${dir.name}", true, success.readbackMatch)

            // 检查字节级与 Golden 严格一致
            assertEquals("Must have 1 published entry for ${dir.name}", 1, samplePublisher.entries.size)
            val published = samplePublisher.entries.values.first()
            assertEquals(false, published.isPending)
            assertNotNull(published.data)
            val publishedSha = sha256(published.data!!)
            assertEquals("Byte-for-byte SHA-256 match for ${dir.name}", goldenSha, publishedSha)

            // 检查 bytesRead, bytesWritten, readbackBytes
            assertEquals(inputFile.length(), success.bytesRead)
            assertEquals(goldenOutputFile.length(), success.bytesWritten)
            assertTrue("Readback bytes must be > 0 and in KB level", success.readbackBytes in 1..65536)
        }
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

    private fun buildLivePairItems(pairName: String): Pair<List<PairFinalizeItem>, List<String>> {
        val goldenRoot = findGoldenRoot()
        val photoDir = File(goldenRoot, "${pairName}_photo")
        val videoDir = File(goldenRoot, "${pairName}_video")
        assertTrue("Missing ${photoDir.absolutePath}", photoDir.exists())
        assertTrue("Missing ${videoDir.absolutePath}", videoDir.exists())

        fun makeItem(dir: File, jobId: String, mime: String, category: JobCategory): Pair<PairFinalizeItem, String> {
            val inputFile = dir.listFiles()?.firstOrNull { it.name.startsWith("input.") }
                ?: error("Missing input file in ${dir.name}")
            val goldenFile = dir.listFiles()?.firstOrNull { it.name.startsWith("golden_output.") }
                ?: error("Missing golden_output file in ${dir.name}")
            val recordMap = JSONObject(File(dir, "provenance.json").readText()).toMap()
            val partFile = File(transfersDir, "$jobId.part").apply { writeBytes(inputFile.readBytes()) }
            val pairId = recordMap["pairId"] as? String ?: pairName
            val job = TransferJob(
                jobId = jobId,
                pairId = pairId,
                category = category,
                totalBytes = inputFile.length(),
            )
            store.insertOrReplace(job)
            val meta = TransferMeta(
                url = "https://example.com/${inputFile.name}",
                total = inputFile.length(),
                mime = mime,
                provenance = recordMap,
            )
            return PairFinalizeItem(job, meta, partFile) to sha256(goldenFile)
        }

        val (photoItem, photoSha) = makeItem(photoDir, "${pairName}_photo_job", "image/jpeg", JobCategory.IMAGE)
        val (videoItem, videoSha) = makeItem(videoDir, "${pairName}_video_job", "video/mp4", JobCategory.LARGE_FILE)
        return listOf(photoItem, videoItem) to listOf(photoSha, videoSha)
    }

    @Test
    fun testLivePairGoldenSamplesConsistencyWithFakeMediaPublisher() {
        for (pairName in listOf("live_1", "live_2")) {
            val samplePublisher = FakeMediaPublisher()
            val sampleFinalizer = TransferFinalizer(transfersDir, store, samplePublisher)
            val (items, goldenShas) = buildLivePairItems(pairName)

            val outcome = runOnBg { sampleFinalizer.executePair(items) }
            assertTrue("Live pair $pairName must succeed", outcome is PairFinalizeOutcome.Success)
            val success = outcome as PairFinalizeOutcome.Success
            assertEquals(2, samplePublisher.entries.size)
            assertTrue(samplePublisher.entries.values.none { it.isPending })

            val photoOut = success.outcomes[items[0].job.jobId]!!
            val videoOut = success.outcomes[items[1].job.jobId]!!
            val expectedSourceId = items[0].meta.provenance!!["sourceId"] as String
            val expectedItemIdx = (items[0].meta.provenance!!["itemIndex"] as Number).toInt()
            val expectedPairId = items[0].meta.provenance!!["pairId"] as String

            assertEquals("${expectedSourceId}_${expectedItemIdx}.jpg", photoOut.publishedMedia.title)
            assertEquals("${expectedSourceId}_${expectedItemIdx}.mp4", videoOut.publishedMedia.title)

            val photoEntry = samplePublisher.entries[photoOut.publishedMedia.mediaId]!!
            val videoEntry = samplePublisher.entries[videoOut.publishedMedia.mediaId]!!
            assertEquals(goldenShas[0], sha256(photoEntry.data!!))
            assertEquals(goldenShas[1], sha256(videoEntry.data!!))

            val photoRead = ProvenanceReader.readProvenance(samplePublisher.openSeekableInput(photoOut.publishedMedia.mediaId))
            val videoRead = ProvenanceReader.readProvenance(samplePublisher.openSeekableInput(videoOut.publishedMedia.mediaId))
            assertEquals(expectedPairId, photoRead?.pairId)
            assertEquals(expectedPairId, videoRead?.pairId)
        }
    }

    @Test
    fun testLivePair_killAfterFirstInsert_recoversToCleanPair() {
        val (items, goldenShas) = buildLivePairItems("live_1")
        finalizer.onStageForTesting = { jobId, stage ->
            if (jobId == items[0].job.jobId && stage == "after_insert") {
                throw SimulatedKillException("kill_after_1st_insert")
            }
        }
        try {
            runOnBg { finalizer.executePair(items) }
            fail("Expected SimulatedKillException")
        } catch (_: SimulatedKillException) {
            // expected kill
        }

        // 此时仅第一个已插入(pending)，第二个未插入，已发布数为 0
        assertEquals(1, publisher.entries.size)
        assertEquals(0, publisher.entries.values.count { !it.isPending })

        // 模拟重启恢复
        val recoveredJobs = items.map { store.getJob(it.job.jobId)!! }
        val recoveredItems = items.mapIndexed { idx, it -> it.copy(job = recoveredJobs[idx]) }
        val freshFinalizer = TransferFinalizer(transfersDir, store, publisher)
        val outcome = runOnBg { freshFinalizer.executePair(recoveredItems) }
        assertTrue(outcome is PairFinalizeOutcome.Success)

        val success = outcome as PairFinalizeOutcome.Success
        assertEquals(2, publisher.entries.size)
        assertTrue(publisher.entries.values.none { it.isPending })
        assertEquals(goldenShas[0], sha256(publisher.entries[success.outcomes[items[0].job.jobId]!!.publishedMedia.mediaId]!!.data!!))
        assertEquals(goldenShas[1], sha256(publisher.entries[success.outcomes[items[1].job.jobId]!!.publishedMedia.mediaId]!!.data!!))
    }

    @Test
    fun testLivePair_killAfterSecondInsert_recoversToCleanPair() {
        val (items, goldenShas) = buildLivePairItems("live_1")
        finalizer.onStageForTesting = { jobId, stage ->
            if (jobId == items[1].job.jobId && stage == "after_insert") {
                throw SimulatedKillException("kill_after_2nd_insert")
            }
        }
        try {
            runOnBg { finalizer.executePair(items) }
            fail("Expected SimulatedKillException")
        } catch (_: SimulatedKillException) {
            // expected kill
        }

        // 两个都已插入但均未发布
        assertEquals(2, publisher.entries.size)
        assertEquals(0, publisher.entries.values.count { !it.isPending })

        val recoveredJobs = items.map { store.getJob(it.job.jobId)!! }
        val recoveredItems = items.mapIndexed { idx, it -> it.copy(job = recoveredJobs[idx]) }
        val freshFinalizer = TransferFinalizer(transfersDir, store, publisher)
        val outcome = runOnBg { freshFinalizer.executePair(recoveredItems) }
        assertTrue(outcome is PairFinalizeOutcome.Success)

        val success = outcome as PairFinalizeOutcome.Success
        assertEquals(2, publisher.entries.size)
        assertTrue(publisher.entries.values.none { it.isPending })
        assertEquals(goldenShas[0], sha256(publisher.entries[success.outcomes[items[0].job.jobId]!!.publishedMedia.mediaId]!!.data!!))
        assertEquals(goldenShas[1], sha256(publisher.entries[success.outcomes[items[1].job.jobId]!!.publishedMedia.mediaId]!!.data!!))
    }

    @Test
    fun testLivePair_killDuringPublish_recoversToCleanPairWithoutDuplicates() {
        val (items, goldenShas) = buildLivePairItems("live_2")
        finalizer.onStageForTesting = { jobId, stage ->
            if (jobId == items[0].job.jobId && stage == "after_publish") {
                throw SimulatedKillException("kill_during_publish")
            }
        }
        try {
            runOnBg { finalizer.executePair(items) }
            fail("Expected SimulatedKillException")
        } catch (_: SimulatedKillException) {
            // expected kill
        }

        // 第一个已发布，第二个仍为 pending
        assertEquals(2, publisher.entries.size)
        assertEquals(1, publisher.entries.values.count { !it.isPending })

        val recoveredJobs = items.map { store.getJob(it.job.jobId)!! }
        val recoveredItems = items.mapIndexed { idx, it -> it.copy(job = recoveredJobs[idx]) }
        val freshFinalizer = TransferFinalizer(transfersDir, store, publisher)
        val outcome = runOnBg { freshFinalizer.executePair(recoveredItems) }
        assertTrue(outcome is PairFinalizeOutcome.Success)

        val success = outcome as PairFinalizeOutcome.Success
        assertEquals(2, publisher.entries.size)
        assertTrue(publisher.entries.values.none { it.isPending })
        assertEquals(goldenShas[0], sha256(publisher.entries[success.outcomes[items[0].job.jobId]!!.publishedMedia.mediaId]!!.data!!))
        assertEquals(goldenShas[1], sha256(publisher.entries[success.outcomes[items[1].job.jobId]!!.publishedMedia.mediaId]!!.data!!))
    }

    @Test
    fun testLivePair_secondFailsValidation_neitherEntersAlbum() {
        val (items, _) = buildLivePairItems("live_1")
        // 破坏第二个视频文件长度使其校验失败
        val brokenVideoMeta = items[1].meta.copy(total = items[1].partFile.length() + 999)
        val brokenItems = listOf(items[0], items[1].copy(meta = brokenVideoMeta))

        val outcome = runOnBg { finalizer.executePair(brokenItems) }
        assertTrue(outcome is PairFinalizeOutcome.Failed)
        assertEquals(0, publisher.entries.size)
    }
}
