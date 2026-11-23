package com.james.easysave.transfer

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Worker 执行结果。
 */
sealed class WorkerResult {
    data class Success(val message: String = "ok") : WorkerResult()
    data class NetworkError(val error: String = "network_error") : WorkerResult()
    data class OtherError(val error: String = "other_error") : WorkerResult()
    data class StorageFull(val error: String = "storage_full") : WorkerResult()
}

/**
 * 传输 Worker 抽象接口。本步为假 Worker，不接真实网络，不写 .part。
 */
interface TransferWorker {
    suspend fun execute(
        job: TransferJob,
        onProgress: suspend (bytesRead: Long, totalBytes: Long) -> Unit,
    ): WorkerResult
}

/**
 * 假 Worker 实现，支持可配置的成功/网络错误/其他错误/空间不足/多次进度上报。
 */
class FakeWorker(
    private val defaultResult: WorkerResult = WorkerResult.Success(),
    private val progressSteps: Int = 2,
    private val stepBytes: Long = 512 * 1024L,
    private val customPlanProvider: ((job: TransferJob, attempt: Int) -> FakePlan?)? = null,
) : TransferWorker {

    data class FakePlan(
        val result: WorkerResult,
        val progressReports: List<Pair<Long, Long>> = listOf(512 * 1024L to 1024 * 1024L, 1024 * 1024L to 1024 * 1024L),
    )

    private val attemptCounters = ConcurrentHashMap<String, AtomicInteger>()

    fun resetAttempts() {
        attemptCounters.clear()
    }

    override suspend fun execute(
        job: TransferJob,
        onProgress: suspend (bytesRead: Long, totalBytes: Long) -> Unit,
    ): WorkerResult {
        val counter = attemptCounters.computeIfAbsent(job.jobId) { AtomicInteger(0) }
        val attempt = counter.getAndIncrement()

        // 1. 自定义计划优先
        val customPlan = customPlanProvider?.invoke(job, attempt)
        if (customPlan != null) {
            for (p in customPlan.progressReports) {
                onProgress(p.first, p.second)
            }
            return customPlan.result
        }

        // 2. 根据 job.fakePlan 解析
        val planName = job.fakePlan ?: "success"
        when (planName) {
            "success", "plan_success" -> {
                onProgress(stepBytes, stepBytes * progressSteps)
                onProgress(stepBytes * progressSteps, stepBytes * progressSteps)
                return WorkerResult.Success()
            }
            "network_once", "plan_network_once" -> {
                if (attempt == 0) {
                    return WorkerResult.NetworkError("simulated_network_error")
                } else {
                    onProgress(stepBytes, stepBytes * 2)
                    onProgress(stepBytes * 2, stepBytes * 2)
                    return WorkerResult.Success()
                }
            }
            "other_twice", "plan_other_twice", "other_error_twice" -> {
                if (attempt < 2) {
                    return WorkerResult.OtherError("simulated_other_error_$attempt")
                } else {
                    onProgress(stepBytes, stepBytes * 2)
                    onProgress(stepBytes * 2, stepBytes * 2)
                    return WorkerResult.Success()
                }
            }
            "network_always" -> {
                return WorkerResult.NetworkError("simulated_network_error_always")
            }
            "other_always" -> {
                return WorkerResult.OtherError("simulated_other_error_always")
            }
            "storage_full", "plan_storage_full" -> {
                return WorkerResult.StorageFull("simulated_storage_full")
            }
            else -> {
                for (i in 1..progressSteps) {
                    onProgress(stepBytes * i, stepBytes * progressSteps)
                }
                return defaultResult
            }
        }
    }
}

