package com.james.easysave.transfer

/**
 * 传输方向。阶段 0 仅使用 DOWNLOAD。
 */
enum class Direction(val value: String) {
    DOWNLOAD("download"),
    UPLOAD("upload");

    companion object {
        fun fromValue(value: String): Direction {
            return entries.firstOrNull { it.value.equals(value, ignoreCase = true) } ?: DOWNLOAD
        }
    }
}

/**
 * 传输任务分类：图片类（并发 3）、大文件类（并发 1）。
 */
enum class JobCategory(val value: String) {
    IMAGE("image"),
    LARGE_FILE("large_file");

    companion object {
        fun fromValue(value: String): JobCategory {
            return entries.firstOrNull { it.value.equals(value, ignoreCase = true) } ?: IMAGE
        }
    }
}

/**
 * 传输任务领域模型。
 *
 * 保证不存储 cookie、token 以及完整 URL 的 query。
 */
data class TransferJob(
    val jobId: String,
    val direction: Direction = Direction.DOWNLOAD,
    var state: JobState = JobState.QUEUED,
    var retryCount: Int = 0,
    var batchId: String? = null,
    val category: JobCategory = JobCategory.IMAGE,
    val createdAt: Long = System.currentTimeMillis(),
    var updatedAt: Long = System.currentTimeMillis(),
    val fakePlan: String? = null,
    var bytesRead: Long = 0L,
    var totalBytes: Long = 0L,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "jobId" to jobId,
        "direction" to direction.value,
        "state" to state.value,
        "retryCount" to retryCount,
        "batchId" to batchId,
        "category" to category.value,
        "createdAt" to createdAt,
        "updatedAt" to updatedAt,
        "bytesRead" to bytesRead,
        "totalBytes" to totalBytes,
        "fakePlan" to fakePlan,
    )
}

/**
 * 传输状态事件。
 */
sealed class TransferEvent {
    data class StateChanged(
        val jobId: String,
        val from: JobState,
        val to: JobState,
        val reason: String?,
        val retryCount: Int,
    ) : TransferEvent() {
        fun toMap(): Map<String, Any?> = mapOf(
            "type" to "state_change",
            "jobId" to jobId,
            "from" to from.value,
            "to" to to.value,
            "reason" to reason,
            "retryCount" to retryCount,
        )
    }

    data class Progress(
        val jobId: String,
        val bytesRead: Long,
        val totalBytes: Long,
    ) : TransferEvent() {
        fun toMap(): Map<String, Any?> = mapOf(
            "type" to "progress",
            "jobId" to jobId,
            "bytesRead" to bytesRead,
            "totalBytes" to totalBytes,
        )
    }
}

