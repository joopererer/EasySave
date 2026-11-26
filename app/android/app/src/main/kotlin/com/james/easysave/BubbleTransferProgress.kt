package com.james.easysave

import com.james.easysave.transfer.Direction
import com.james.easysave.transfer.JobState
import com.james.easysave.transfer.TransferJob

/**
 * Computed UI state for [OverlayService] from native [TransferJob] snapshots.
 * Pure Kotlin so it can be unit-tested on JVM without Android framework mocks.
 */
data class BubbleTransferSnapshot(
    val state: BubbleState,
    val doneCount: Int,
    val totalCount: Int,
    val overallProgress: Float,
    val innerProgress: Float,
    val showInnerRing: Boolean,
    val displayPercent: Int?,
    val activeBatchCount: Int,
    val activeJobCount: Int,
    val currentJobId: String?,
) {
    companion object {
        val IDLE = BubbleTransferSnapshot(
            state = BubbleState.IDLE,
            doneCount = 0,
            totalCount = 0,
            overallProgress = 0f,
            innerProgress = 0f,
            showInnerRing = false,
            displayPercent = null,
            activeBatchCount = 0,
            activeJobCount = 0,
            currentJobId = null,
        )
    }
}

object BubbleTransferProgress {
    /** Warm cream yellow adjusted from #FFE8A3 for WCAG contrast on #FC494C-#FA662E. */
    const val INNER_RING_COLOR: Int = 0xFFFFF4BD.toInt()
    const val INNER_TRACK_COLOR: Int = 0x55000000
    const val TEXT_SHADOW_COLOR: Int = 0xCC000000.toInt()

    private fun isActiveState(state: JobState): Boolean =
        state == JobState.QUEUED ||
            state == JobState.RUNNING ||
            state == JobState.FINISHING ||
            state == JobState.WAITING_PAIR ||
            state == JobState.WAITING_NETWORK

    private fun isTransferringState(state: JobState): Boolean =
        state == JobState.RUNNING ||
            state == JobState.FINISHING ||
            state == JobState.WAITING_PAIR

    fun compute(
        jobs: Collection<TransferJob>,
        trackedBatchId: String? = null,
    ): Pair<BubbleTransferSnapshot, String?> {
        val downloadJobs = jobs.filter { it.direction == Direction.DOWNLOAD && !it.batchId.isNullOrEmpty() }
        if (downloadJobs.isEmpty()) {
            return BubbleTransferSnapshot.IDLE to null
        }

        val activeJobs = downloadJobs.filter { isActiveState(it.state) }
        val activeBatches = activeJobs.mapNotNull { it.batchId }.distinct()

        val targetBatchId: String? = when {
            activeJobs.isNotEmpty() -> {
                if (trackedBatchId != null && activeBatches.contains(trackedBatchId)) {
                    trackedBatchId
                } else {
                    activeJobs.maxByOrNull { it.updatedAt }?.batchId
                }
            }
            trackedBatchId != null -> trackedBatchId
            else -> null
        }

        if (targetBatchId == null) {
            return BubbleTransferSnapshot.IDLE to null
        }

        val batchJobs = downloadJobs.filter {
            it.batchId == targetBatchId && it.state != JobState.CANCELED
        }
        if (batchJobs.isEmpty()) {
            return BubbleTransferSnapshot.IDLE to null
        }

        val totalCount = batchJobs.size
        val doneCount = batchJobs.count { it.state == JobState.DONE }
        val batchActive = batchJobs.any { isActiveState(it.state) }

        if (!batchActive) {
            val anyFailed = batchJobs.any { it.state == JobState.FAILED }
            val terminalState = if (anyFailed && doneCount == 0) BubbleState.ERROR else BubbleState.DONE
            return BubbleTransferSnapshot(
                state = terminalState,
                doneCount = doneCount,
                totalCount = totalCount,
                overallProgress = if (terminalState == BubbleState.DONE) 1f else 0f,
                innerProgress = if (terminalState == BubbleState.DONE) 1f else 0f,
                showInnerRing = false,
                displayPercent = null,
                activeBatchCount = activeBatches.size,
                activeJobCount = activeJobs.size,
                currentJobId = null,
            ) to null
        }

        // Overall progress: byte-weighted across jobs with known total, fallback to count ratio.
        var sumTotal = 0L
        var sumRead = 0L
        for (j in batchJobs) {
            val jobTotal = when {
                j.totalBytes > 0L -> j.totalBytes
                j.fileSize > 0L -> j.fileSize
                else -> 0L
            }
            if (jobTotal <= 0L) continue
            sumTotal += jobTotal
            sumRead += if (j.state == JobState.DONE) {
                jobTotal
            } else {
                j.bytesRead.coerceIn(0L, jobTotal)
            }
        }
        val overallProgress = if (sumTotal > 0L) {
            (sumRead.toDouble() / sumTotal.toDouble()).toFloat().coerceIn(0f, 1f)
        } else {
            (doneCount.toFloat() / totalCount.toFloat()).coerceIn(0f, 1f)
        }

        if (totalCount <= 1) {
            val overallPct = if (sumTotal > 0L) {
                (overallProgress * 100f).roundToInt().coerceIn(0, 100)
            } else {
                null
            }
            return BubbleTransferSnapshot(
                state = BubbleState.BUSY,
                doneCount = doneCount,
                totalCount = totalCount,
                overallProgress = overallProgress,
                innerProgress = overallProgress,
                showInnerRing = false,
                displayPercent = overallPct,
                activeBatchCount = activeBatches.size,
                activeJobCount = activeJobs.size,
                currentJobId = batchJobs.firstOrNull()?.jobId,
            ) to targetBatchId
        }

        // Multiple files: pick the transferring job with the most bytesRead (or any active job).
        val transferring = batchJobs.filter { isTransferringState(it.state) }
        val currentJob = transferring.maxByOrNull { it.bytesRead }
            ?: batchJobs.firstOrNull { isActiveState(it.state) }

        val innerProgress: Float
        val innerPct: Int?
        if (currentJob != null && currentJob.totalBytes > 0L) {
            innerProgress = (currentJob.bytesRead.toDouble() / currentJob.totalBytes.toDouble())
                .toFloat()
                .coerceIn(0f, 1f)
            innerPct = (innerProgress * 100f).roundToInt().coerceIn(0, 100)
        } else {
            innerProgress = 0f
            innerPct = null
        }

        return BubbleTransferSnapshot(
            state = BubbleState.BUSY,
            doneCount = doneCount,
            totalCount = totalCount,
            overallProgress = overallProgress,
            innerProgress = innerProgress,
            showInnerRing = true,
            displayPercent = innerPct,
            activeBatchCount = activeBatches.size,
            activeJobCount = activeJobs.size,
            currentJobId = currentJob?.jobId,
        ) to targetBatchId
    }

    private fun Float.roundToInt(): Int = kotlin.math.round(this).toInt()
}
