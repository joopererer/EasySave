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
    /** Pure white inner ring (#FFFFFF) matching the outer ring, over a 24% black track. */
    const val INNER_RING_COLOR: Int = 0xFFFFFFFF.toInt()
    const val INNER_TRACK_COLOR: Int = 0x3D000000

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
        previousOverallProgress: Float = 0f,
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

        val explicitTotal = batchJobs.maxOfOrNull { it.batchTotalCount } ?: 0
        val totalCount = maxOf(explicitTotal, batchJobs.size)
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

        // Unified overall progress: (doneCount + sum(inProgressRatio)) / N.
        // Done = 1.0, not-started = 0.0, unknown-total in-progress = 0.0, monotonic non-decreasing.
        var inProgressSum = 0.0
        for (j in batchJobs) {
            if (j.state == JobState.DONE) continue
            if (!isTransferringState(j.state)) continue
            if (j.totalBytes > 0L) {
                inProgressSum += (j.bytesRead.toDouble() / j.totalBytes.toDouble()).coerceIn(0.0, 1.0)
            }
        }
        val rawOverall = if (totalCount > 0) {
            ((doneCount.toDouble() + inProgressSum) / totalCount.toDouble()).toFloat().coerceIn(0f, 1f)
        } else {
            0f
        }
        val overallProgress = maxOf(previousOverallProgress.coerceIn(0f, 1f), rawOverall)

        if (totalCount <= 1) {
            val hasKnownTotal = doneCount > 0 || batchJobs.any { it.totalBytes > 0L || it.fileSize > 0L }
            val overallPct = if (hasKnownTotal || overallProgress > 0f) {
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
