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
        // Overall byte-weighted: (1000 + 1000) / (1000 + 9000) = 0.20
        assertEquals(0.20f, snap.overallProgress, 0.001f)
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
}

