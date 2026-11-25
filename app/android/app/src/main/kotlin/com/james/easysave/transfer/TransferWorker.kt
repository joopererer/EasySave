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
    data class StorageFull(
        val error: String = "storage_full",
        val requiredBytes: Long = 0L,
        val availableBytes: Long = 0L,
    ) : WorkerResult()
    data class PolicyRejected(val error: String = "policy_rejected") : WorkerResult()
    data class UrlExpired(val code: Int = 403, val error: String = "url_expired") : WorkerResult()
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
 * FakeWorker 场景与运行计数注册表（服务生命周期单例）。
 *
 * 解决真机上每次创建新 Worker 实例导致运行计数被重置的问题。
 * 计数按 jobId 绑定在服务生命周期内，不随 Worker 实例销毁与重建丢失。
 */
object FakeWorkerRegistry {
    private val attemptCounters = ConcurrentHashMap<String, AtomicInteger>()
    private val customPlans = ConcurrentHashMap<String, (job: TransferJob, attempt: Int) -> FakeWorker.FakePlan?>()

    fun getAttempt(jobId: String): Int {
        return attemptCounters.computeIfAbsent(jobId) { AtomicInteger(0) }.getAndIncrement()
    }

    fun peekAttempt(jobId: String): Int {
        return attemptCounters[jobId]?.get() ?: 0
    }

    fun registerCustomPlan(jobId: String, planProvider: (job: TransferJob, attempt: Int) -> FakeWorker.FakePlan?) {
        customPlans[jobId] = planProvider
    }

    fun getCustomPlan(job: TransferJob, attempt: Int): FakeWorker.FakePlan? {
        return customPlans[job.jobId]?.invoke(job, attempt)
    }

    fun reset(jobId: String? = null) {
        if (jobId != null) {
            attemptCounters.remove(jobId)
            customPlans.remove(jobId)
        } else {
            attemptCounters.clear()
            customPlans.clear()
        }
    }
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
        val progressReports: List<Pair<Long, Long>> = listOf(
            512 * 1024L to 1024 * 1024L,
            1024 * 1024L to 1024 * 1024L
        ),
    )

    override suspend fun execute(
        job: TransferJob,
        onProgress: suspend (bytesRead: Long, totalBytes: Long) -> Unit,
    ): WorkerResult {
        // 从单例注册表中获取累加运行次数，确保跨 Worker 实例重建不被重置
        val attempt = FakeWorkerRegistry.getAttempt(job.jobId)

        // 1. 优先查实例级或注册表级自定义计划
        val customPlan = customPlanProvider?.invoke(job, attempt) ?: FakeWorkerRegistry.getCustomPlan(job, attempt)
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
