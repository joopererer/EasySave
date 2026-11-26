package com.james.easysave

import com.james.easysave.transfer.Direction
import com.james.easysave.transfer.JobCategory
import com.james.easysave.transfer.JobState
import com.james.easysave.transfer.TransferEvent
import com.james.easysave.transfer.TransferJob
import com.james.easysave.transfer.TransferService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BubbleTransferProgressTest {

    @Test
    fun singleFileBatch_hidesInnerRingAndShowsOverallPercent() {
        val job = TransferJob(
            jobId = "j1",
            direction = Direction.DOWNLOAD,
            state = JobState.RUNNING,
            batchId = "b-single",
            category = JobCategory.LARGE_FILE,
            bytesRead = 450L,
            totalBytes = 1000L,
        )
        val (snap, tracked) = BubbleTransferProgress.compute(listOf(job))
        assertEquals("b-single", tracked)
        assertEquals(BubbleState.BUSY, snap.state)
        assertEquals(0, snap.doneCount)
        assertEquals(1, snap.totalCount)
        assertFalse(snap.showInnerRing)
        assertEquals(0.45f, snap.overallProgress, 0.001f)
        assertEquals(45, snap.displayPercent)
    }

    @Test
    fun multiFileBatch_showsInnerRingAndByteWeightedOverall() {
        val j1 = TransferJob(
            jobId = "j1",
            direction = Direction.DOWNLOAD,
            state = JobState.DONE,
            batchId = "b-multi",
            category = JobCategory.IMAGE,
            bytesRead = 1000L,
            totalBytes = 1000L,
            fileSize = 1000L,
        )
        val j2 = TransferJob(
            jobId = "j2",
            direction = Direction.DOWNLOAD,
            state = JobState.RUNNING,
            batchId = "b-multi",
            category = JobCategory.LARGE_FILE,
            bytesRead = 1000L,
            totalBytes = 9000L,
        )
        val (snap, tracked) = BubbleTransferProgress.compute(listOf(j1, j2))
        assertEquals("b-multi", tracked)
        assertEquals(BubbleState.BUSY, snap.state)
        assertEquals(1, snap.doneCount)
        assertEquals(2, snap.totalCount)
        assertTrue(snap.showInnerRing)
        // Unified overall progress: (1 + 1000 / 9000) / 2 = 0.5556
        assertEquals((1.0f + 1000f / 9000f) / 2f, snap.overallProgress, 0.001f)
        // Inner ring: j2 = 1000 / 9000 = 0.111 -> 11%
        assertEquals(1000f / 9000f, snap.innerProgress, 0.001f)
        assertEquals(11, snap.displayPercent)
    }

    @Test
    fun concurrentJobs_innerRingPicksMostBytesRead() {
        val j1 = TransferJob(
            jobId = "img1",
            direction = Direction.DOWNLOAD,
            state = JobState.RUNNING,
            batchId = "b-conc",
            category = JobCategory.IMAGE,
            bytesRead = 200L,
            totalBytes = 1000L,
        )
        val j2 = TransferJob(
            jobId = "img2",
            direction = Direction.DOWNLOAD,
            state = JobState.RUNNING,
            batchId = "b-conc",
            category = JobCategory.IMAGE,
            bytesRead = 800L,
            totalBytes = 1000L,
        )
        val j3 = TransferJob(
            jobId = "img3",
            direction = Direction.DOWNLOAD,
            state = JobState.RUNNING,
            batchId = "b-conc",
            category = JobCategory.IMAGE,
            bytesRead = 500L,
            totalBytes = 1000L,
        )
        val (snap, _) = BubbleTransferProgress.compute(listOf(j1, j2, j3))
        assertTrue(snap.showInnerRing)
        assertEquals("img2", snap.currentJobId)
        assertEquals(80, snap.displayPercent)
        assertEquals(0.8f, snap.innerProgress, 0.001f)
        // Overall: (200 + 800 + 500) / 3000 = 0.50
        assertEquals(0.50f, snap.overallProgress, 0.001f)
    }

    @Test
    fun completedTrackedBatch_transitionsToDoneAndClearsTracked() {
        val j1 = TransferJob(
            jobId = "j1",
            direction = Direction.DOWNLOAD,
            state = JobState.DONE,
            batchId = "b-done",
            category = JobCategory.IMAGE,
            bytesRead = 1000L,
            totalBytes = 1000L,
            fileSize = 1000L,
        )
        val (snap, nextTracked) = BubbleTransferProgress.compute(listOf(j1), trackedBatchId = "b-done")
        assertEquals(BubbleState.DONE, snap.state)
        assertNull(nextTracked)
        assertFalse(snap.showInnerRing)
        assertNull(snap.displayPercent)
    }

    @Test
    fun transferServiceNativeListener_receivesProgressAndCompletionWithoutFlutterEngine() {
        val job = TransferJob(
            jobId = "native-j1",
            direction = Direction.DOWNLOAD,
            state = JobState.RUNNING,
            batchId = "b-native",
            category = JobCategory.LARGE_FILE,
            bytesRead = 500L,
            totalBytes = 1000L,
        )

        val received = mutableListOf<TransferEvent>()
        val listener: (TransferEvent) -> Unit = { event ->
            received.add(event)
            when (event) {
                is TransferEvent.Progress -> {
                    job.bytesRead = event.bytesRead
                    job.totalBytes = event.totalBytes
                }
                is TransferEvent.Completed -> {
                    job.state = JobState.DONE
                    job.fileSize = event.fileSize
                    job.bytesRead = event.fileSize
                }
                else -> {}
            }
        }
        TransferService.addTransferListener(listener)
        try {
            val (snap0, tracked0) = BubbleTransferProgress.compute(listOf(job))
            assertEquals("b-native", tracked0)
            assertEquals(BubbleState.BUSY, snap0.state)
            assertEquals(50, snap0.displayPercent)

            listener(TransferEvent.Progress("native-j1", 750L, 1000L))
            val (snap1, _) = BubbleTransferProgress.compute(listOf(job), tracked0)
            assertEquals(75, snap1.displayPercent)

            listener(
                TransferEvent.Completed(
                    jobId = "native-j1",
                    mediaId = "m1",
                    title = "1.mp4",
                    relativePath = "Movies/EasySave",
                    md5 = "abc",
                    fileSize = 1000L,
                ),
            )
            val (snap2, tracked2) = BubbleTransferProgress.compute(listOf(job), tracked0)
            assertEquals(BubbleState.DONE, snap2.state)
            assertNull(tracked2)
            assertEquals(2, received.size)
        } finally {
            TransferService.removeTransferListener(listener)
        }
    }

    @Test
    fun whiteDualRingStyle_usesWhiteAnd20to25PercentBlackTrack() {
        assertEquals(0xFFFFFFFF.toInt(), BubbleTransferProgress.INNER_RING_COLOR)
        val alpha = (BubbleTransferProgress.INNER_TRACK_COLOR ushr 24) and 0xFF
        val rgb = BubbleTransferProgress.INNER_TRACK_COLOR and 0x00FFFFFF
        assertEquals(0, rgb)
        assertTrue("Track alpha $alpha should be 20%-25% (51..64)", alpha in 51..64)
    }

    @Test
    fun sharedVectors_matchUnifiedOverallProgressAndMonotonicity() {
        val candidates = listOf(
            java.io.File("spec/batch_progress_vectors.json"),
            java.io.File("../spec/batch_progress_vectors.json"),
            java.io.File("../../spec/batch_progress_vectors.json"),
            java.io.File("../../../spec/batch_progress_vectors.json"),
        )
        val file = candidates.firstOrNull { it.exists() }
            ?: error("Could not locate spec/batch_progress_vectors.json from ${java.io.File(".").absolutePath}")
        val root = parseSimpleJson(file.readText()) as Map<*, *>
        val vectors = root["vectors"] as List<*>
        assertTrue(vectors.isNotEmpty())
        for (raw in vectors) {
            val v = raw as Map<*, *>
            val name = v["name"] as String
            val batchTotalCount = (v["batchTotalCount"] as Number).toInt()
            val prevOverall = (v["previousOverallProgress"] as Number).toFloat()
            val rawJobs = v["jobs"] as List<*>
            val jobs = rawJobs.mapIndexed { idx, rj ->
                val jm = rj as Map<*, *>
                TransferJob(
                    jobId = jm["jobId"] as String,
                    direction = Direction.DOWNLOAD,
                    state = JobState.fromValue(jm["state"] as String),
                    batchId = "vec-$name",
                    category = JobCategory.IMAGE,
                    bytesRead = (jm["bytesRead"] as Number).toLong(),
                    totalBytes = (jm["totalBytes"] as Number).toLong(),
                    batchTotalCount = if (idx == 0) batchTotalCount else 0,
                )
            }
            val (snap, _) = BubbleTransferProgress.compute(
                jobs,
                trackedBatchId = "vec-$name",
                previousOverallProgress = prevOverall,
            )
            val expOverall = (v["expectedOverallProgress"] as Number).toFloat()
            val expTotal = (v["expectedTotalCount"] as Number).toInt()
            val expDone = (v["expectedDoneCount"] as Number).toInt()
            val expInnerRing = v["expectedShowInnerRing"] as Boolean
            val expPct = (v["expectedDisplayPercent"] as Number?)?.toInt()
            assertEquals("[$name] overallProgress", expOverall, snap.overallProgress, 0.001f)
            assertEquals("[$name] totalCount", expTotal, snap.totalCount)
            assertEquals("[$name] doneCount", expDone, snap.doneCount)
            assertEquals("[$name] showInnerRing", expInnerRing, snap.showInnerRing)
            assertEquals("[$name] displayPercent", expPct, snap.displayPercent)
            val expInner = (v["expectedInnerProgress"] as Number?)?.toFloat()
            if (expInner != null) {
                assertEquals("[$name] innerProgress", expInner, snap.innerProgress, 0.001f)
            }
        }
    }

    private fun parseSimpleJson(src: String): Any? {
        var i = 0
        fun skipWs() {
            while (i < src.length && src[i].isWhitespace()) i++
        }
        fun parseString(): String {
            i++ // skip '"'
            val sb = StringBuilder()
            while (i < src.length) {
                val c = src[i++]
                if (c == '"') return sb.toString()
                if (c == '\\' && i < src.length) {
                    val n = src[i++]
                    sb.append(when (n) {
                        '"', '\\', '/' -> n
                        'n' -> '\n'
                        'r' -> '\r'
                        't' -> '\t'
                        else -> n
                    })
                } else {
                    sb.append(c)
                }
            }
            return sb.toString()
        }
        fun parseValue(): Any? {
            skipWs()
            if (i >= src.length) return null
            return when (src[i]) {
                '{' -> {
                    i++
                    val map = linkedMapOf<String, Any?>()
                    skipWs()
                    if (i < src.length && src[i] == '}') { i++; return map }
                    while (i < src.length) {
                        skipWs()
                        val key = parseString()
                        skipWs()
                        if (i < src.length && src[i] == ':') i++
                        map[key] = parseValue()
                        skipWs()
                        if (i < src.length && src[i] == ',') { i++; continue }
                        if (i < src.length && src[i] == '}') { i++; break }
                    }
                    map
                }
                '[' -> {
                    i++
                    val list = mutableListOf<Any?>()
                    skipWs()
                    if (i < src.length && src[i] == ']') { i++; return list }
                    while (i < src.length) {
                        list.add(parseValue())
                        skipWs()
                        if (i < src.length && src[i] == ',') { i++; continue }
                        if (i < src.length && src[i] == ']') { i++; break }
                    }
                    list
                }
                '"' -> parseString()
                't' -> { i += 4; true }
                'f' -> { i += 5; false }
                'n' -> { i += 4; null }
                else -> {
                    val start = i
                    while (i < src.length && (src[i].isDigit() || src[i] in listOf('-', '+', '.', 'e', 'E'))) i++
                    val numStr = src.substring(start, i)
                    if (numStr.contains('.') || numStr.contains('e') || numStr.contains('E')) {
                        numStr.toDouble()
                    } else {
                        numStr.toLong()
                    }
                }
            }
        }
        return parseValue()
    }
}

