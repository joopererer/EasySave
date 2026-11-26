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
    val pairId: String? = null,
    val category: JobCategory = JobCategory.IMAGE,
    val createdAt: Long = System.currentTimeMillis(),
    var updatedAt: Long = System.currentTimeMillis(),
    val fakePlan: String? = null,
    var bytesRead: Long = 0L,
    var totalBytes: Long = 0L,
    var finalizeStep: String? = null,
    var mediaId: String? = null,
    var title: String? = null,
    var relativePath: String? = null,
    var md5: String? = null,
    var fileSize: Long = 0L,
    var partSha256: String? = null,
    var verifyMs: Long = 0L,
    var provenanceMs: Long = 0L,
    var importMs: Long = 0L,
    var readbackMs: Long = 0L,
    var provenanceStatus: String? = null,
    var readbackMatch: Boolean? = null,
    var historyPending: Boolean = false,
    val batchTotalCount: Int = 0,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "jobId" to jobId,
        "direction" to direction.value,
        "state" to state.value,
        "retryCount" to retryCount,
        "batchId" to batchId,
        "pairId" to pairId,
        "category" to category.value,
        "createdAt" to createdAt,
        "updatedAt" to updatedAt,
        "bytesRead" to bytesRead,
        "totalBytes" to totalBytes,
        "fakePlan" to fakePlan,
        "finalizeStep" to finalizeStep,
        "mediaId" to mediaId,
        "title" to title,
        "relativePath" to relativePath,
        "md5" to md5,
        "fileSize" to fileSize,
        "partSha256" to partSha256,
        "verifyMs" to verifyMs,
        "provenanceMs" to provenanceMs,
        "importMs" to importMs,
        "readbackMs" to readbackMs,
        "provenanceStatus" to provenanceStatus,
        "readbackMatch" to readbackMatch,
        "historyPending" to historyPending,
        "batchTotalCount" to batchTotalCount,
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
        val requiredBytes: Long = 0L,
        val availableBytes: Long = 0L,
    ) : TransferEvent() {
        fun toMap(): Map<String, Any?> = mapOf(
            "type" to "state_change",
            "jobId" to jobId,
            "from" to from.value,
            "to" to to.value,
            "reason" to reason,
            "retryCount" to retryCount,
            if (requiredBytes > 0) "requiredBytes" to requiredBytes else "requiredBytes" to 0L,
            if (availableBytes > 0) "availableBytes" to availableBytes else "availableBytes" to 0L,
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

    data class Completed(
        val jobId: String,
        val mediaId: String?,
        val md5: String?,
        val title: String? = null,
        val fileSize: Long = 0L,
        val relativePath: String? = null,
    ) : TransferEvent() {
        fun toMap(): Map<String, Any?> = mapOf(
            "type" to "completed",
            "jobId" to jobId,
            "mediaId" to mediaId,
            "md5" to md5,
            "title" to title,
            "fileSize" to fileSize,
            "relativePath" to relativePath,
        )
    }

    data class ReresolveRequired(
        val jobId: String,
    ) : TransferEvent() {
        fun toMap(): Map<String, Any?> = mapOf(
            "type" to "reresolve_required",
            "jobId" to jobId,
        )
    }
}

/**
 * 传输下载参数（仅保留在内存中，严格不写入 Store、.meta 和日志）。
 */
data class TransferDownloadParams(
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val cookie: String? = null,
    val allowedCookieDomains: List<String> = emptyList(),
    val policyHosts: List<com.james.easysave.policy.MediaPolicyRedirects.HostRule> = emptyList(),
    val mime: String? = null,
    val policyKey: String? = null,
    val provenance: Map<String, Any?>? = null,
)

/**
 * 传输参数内存注册表。
 */
object TransferParamsRegistry {
    private val paramsMap = java.util.concurrent.ConcurrentHashMap<String, TransferDownloadParams>()

    fun set(jobId: String, params: TransferDownloadParams) {
        paramsMap[jobId] = params
    }

    fun get(jobId: String): TransferDownloadParams? = paramsMap[jobId]

    fun remove(jobId: String): TransferDownloadParams? = paramsMap.remove(jobId)

    fun clear() = paramsMap.clear()
}

