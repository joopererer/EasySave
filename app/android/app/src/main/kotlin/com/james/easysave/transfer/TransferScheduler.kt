package com.james.easysave.transfer

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * 可注入的时钟与定时调度器抽象，允许在单元测试中进行虚拟推进而无需固定 sleep。
 */
interface TransferClock {
    fun currentTimeMillis(): Long
    fun schedule(delayMs: Long, action: () -> Unit): CancellableTimer
}

interface CancellableTimer {
    fun cancel()
}

class CoroutineTransferClock(
    private val scope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
) : TransferClock {
    override fun currentTimeMillis(): Long = System.currentTimeMillis()

    override fun schedule(delayMs: Long, action: () -> Unit): CancellableTimer {
        val job = scope.launch(dispatcher) {
            delay(delayMs)
            if (isActive) {
                action()
            }
        }
        return object : CancellableTimer {
            override fun cancel() {
                job.cancel()
            }
        }
    }
}

/**
 * 调度器事件定义。
 */
sealed class SchedulerEvent {
    data class Enqueue(val job: TransferJob) : SchedulerEvent()
    data class Pause(val jobId: String) : SchedulerEvent()
    data class Resume(val jobId: String) : SchedulerEvent()
    data class Cancel(val jobId: String) : SchedulerEvent()
    data class Retry(val jobId: String) : SchedulerEvent()
    data class NetworkChanged(val isAvailable: Boolean) : SchedulerEvent()
    object NetworkStabilized : SchedulerEvent()
    data class WorkerResultEvent(val jobId: String, val result: WorkerResult) : SchedulerEvent()
    data class WorkerProgressEvent(val jobId: String, val bytesRead: Long, val totalBytes: Long) : SchedulerEvent()
    data class RetryTimerFired(val jobId: String, val attempt: Int) : SchedulerEvent()
    object RestoreFromStore : SchedulerEvent()
    data class ServiceTimeout(val reason: String = "fgs_timeout") : SchedulerEvent()
    data class GetSnapshot(val callback: (List<TransferJob>) -> Unit) : SchedulerEvent()
    data class CustomEvent(val id: Int, val onHandled: (Int) -> Unit) : SchedulerEvent()
}

/**
 * 传输调度器（单线程 actor）。
 *
 * 架构选型理由（协程 Channel）：
 * 1. 原生 Kotlin actor 范式，无缝利用结构化并发与非阻塞挂起；
 * 2. Channel(Channel.UNLIMITED) 保证全局严格 FIFO 投递顺序与单一协程单线程顺序消费；
 * 3. 避免依赖 Android 系统的 HandlerThread/Looper，使得所有业务逻辑与重试时序可在 JVM 单元测试中秒级快速运行；
 * 4. 易于与协程取消、超时、虚拟时钟协同。
 *
 * 并发上限：
 * - 图片类（IMAGE）：3
 * - 大文件类（LARGE_FILE）：1
 *
 * 重试策略：
 * - 网络错误 → waiting_network，不计次数；网络恢复且稳定 3 秒后重新排队；
 * - 其他错误 → 5/15/30/60/120 秒重试 5 次，用完进 interrupted；
 * - 空间不足 → storage_full。
 */
class TransferScheduler(
    val store: TransferStore,
    val workerFactory: (TransferJob) -> TransferWorker = { FakeWorker() },
    val scope: CoroutineScope,
    clock: TransferClock? = null,
    val eventListener: ((TransferEvent) -> Unit)? = null,
    val onIdleChanged: ((isIdle: Boolean) -> Unit)? = null,
) {
    companion object {
        const val MAX_CONCURRENT_IMAGES = 3
        const val MAX_CONCURRENT_LARGE_FILES = 1
        const val NETWORK_STABILIZATION_MS = 3_000L
        val RETRY_DELAYS_MS = longArrayOf(5_000L, 15_000L, 30_000L, 60_000L, 120_000L)
        const val MAX_RETRIES = 5
    }

    val clock: TransferClock = clock ?: CoroutineTransferClock(scope)

    private val channel = Channel<SchedulerEvent>(Channel.UNLIMITED)

    // 内存中的任务镜像
    val jobs = LinkedHashMap<String, TransferJob>()

    // 运行中的 Worker 协程 Handle
    private val runningWorkers = ConcurrentHashMap<String, Job>()

    // 挂起中的定时器
    private val pendingTimers = ConcurrentHashMap<String, CancellableTimer>()

    // 网络稳定定时器
    private var networkStabilizeTimer: CancellableTimer? = null

    // 串行性与并发检查（用于测试验证）
    val activeProcessors = AtomicInteger(0)
    var maxObservedConcurrency = 0

    private var actorJob: Job? = null

    init {
        startActor()
    }

    private fun startActor() {
        actorJob = scope.launch {
            for (event in channel) {
                val current = activeProcessors.incrementAndGet()
                if (current > maxObservedConcurrency) {
                    maxObservedConcurrency = current
                }
                try {
                    handleEvent(event)
                } catch (t: Throwable) {
                    TransferLog.e("Error processing event $event: ${t.message}", t)
                } finally {
                    activeProcessors.decrementAndGet()
                }
            }
        }
    }

    fun send(event: SchedulerEvent) {
        channel.trySend(event)
    }

    suspend fun post(event: SchedulerEvent) {
        channel.send(event)
    }

    private suspend fun handleEvent(event: SchedulerEvent) {
        when (event) {
            is SchedulerEvent.Enqueue -> handleEnqueue(event.job)
            is SchedulerEvent.Pause -> handlePause(event.jobId)
            is SchedulerEvent.Resume -> handleResume(event.jobId)
            is SchedulerEvent.Cancel -> handleCancel(event.jobId)
            is SchedulerEvent.Retry -> handleRetry(event.jobId)
            is SchedulerEvent.NetworkChanged -> handleNetworkChanged(event.isAvailable)
            is SchedulerEvent.NetworkStabilized -> handleNetworkStabilized()
            is SchedulerEvent.WorkerResultEvent -> handleWorkerResult(event.jobId, event.result)
            is SchedulerEvent.WorkerProgressEvent -> handleWorkerProgress(event.jobId, event.bytesRead, event.totalBytes)
            is SchedulerEvent.RetryTimerFired -> handleRetryTimerFired(event.jobId, event.attempt)
            is SchedulerEvent.RestoreFromStore -> handleRestoreFromStore()
            is SchedulerEvent.ServiceTimeout -> handleServiceTimeout(event.reason)
            is SchedulerEvent.GetSnapshot -> event.callback(jobs.values.map { it.copy() })
            is SchedulerEvent.CustomEvent -> event.onHandled(event.id)
        }
    }

    private fun handleEnqueue(newJob: TransferJob) {
        val existing = jobs[newJob.jobId]
        if (existing != null) {
            if (existing.state.isTerminal) {
                // 已终态的任务不重新入队，除非显式 retry
                return
            }
            // 任务已存在且在进行中，忽略重复 enqueue
            return
        }

        // 入库
        store.insertOrReplace(newJob)
        jobs[newJob.jobId] = newJob

        TransferLog.i("job=${TransferLog.shortId(newJob.jobId)} enqueued category=${newJob.category.value}")
        emitStateChange(newJob.jobId, JobState.QUEUED, JobState.QUEUED, "enqueue", newJob.retryCount)

        dispatchNext()
    }

    private fun handlePause(jobId: String) {
        val job = jobs[jobId] ?: return
        if (job.state == JobState.RUNNING) {
            cancelWorker(jobId)
            pendingTimers.remove(jobId)?.cancel()
            if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.PAUSED, "user_paused", job.retryCount)) {
                job.state = JobState.PAUSED
                job.updatedAt = clock.currentTimeMillis()
                store.updateJobState(jobId, JobState.PAUSED, job.retryCount, job.updatedAt)
                emitStateChange(jobId, JobState.RUNNING, JobState.PAUSED, "user_paused", job.retryCount)
            }
            dispatchNext()
        }
    }

    private fun handleResume(jobId: String) {
        val job = jobs[jobId] ?: return
        val fromState = job.state
        if (fromState == JobState.PAUSED ||
            fromState == JobState.WAITING_NETWORK ||
            fromState == JobState.INTERRUPTED ||
            fromState == JobState.STORAGE_FULL
        ) {
            if (JobState.validateAndLog(jobId, fromState, JobState.QUEUED, "user_resume", job.retryCount)) {
                job.state = JobState.QUEUED
                job.updatedAt = clock.currentTimeMillis()
                store.updateJobState(jobId, JobState.QUEUED, job.retryCount, job.updatedAt)
                emitStateChange(jobId, fromState, JobState.QUEUED, "user_resume", job.retryCount)
                dispatchNext()
            }
        }
    }

    private fun handleCancel(jobId: String) {
        val job = jobs[jobId] ?: return
        val fromState = job.state
        if (!fromState.isTerminal) {
            cancelWorker(jobId)
            pendingTimers.remove(jobId)?.cancel()
            if (JobState.validateAndLog(jobId, fromState, JobState.CANCELED, "user_cancel", job.retryCount)) {
                job.state = JobState.CANCELED
                job.updatedAt = clock.currentTimeMillis()
                store.updateJobState(jobId, JobState.CANCELED, job.retryCount, job.updatedAt)
                emitStateChange(jobId, fromState, JobState.CANCELED, "user_cancel", job.retryCount)
                dispatchNext()
            }
        }
    }

    private fun handleRetry(jobId: String) {
        val job = jobs[jobId] ?: return
        val fromState = job.state
        if (fromState == JobState.INTERRUPTED || fromState == JobState.STORAGE_FULL || fromState == JobState.FAILED) {
            // 重置重试次数
            job.retryCount = 0
            val targetState = JobState.QUEUED
            if (JobState.validateAndLog(jobId, fromState, targetState, "user_retry", 0)) {
                job.state = targetState
                job.updatedAt = clock.currentTimeMillis()
                store.updateJobState(jobId, targetState, 0, job.updatedAt)
                emitStateChange(jobId, fromState, targetState, "user_retry", 0)
                dispatchNext()
            }
        }
    }

    private fun handleNetworkChanged(isAvailable: Boolean) {
        if (!isAvailable) {
            networkStabilizeTimer?.cancel()
            networkStabilizeTimer = null
            TransferLog.i("network disconnected")
        } else {
            networkStabilizeTimer?.cancel()
            TransferLog.i("network connected, waiting 3s stabilization")
            networkStabilizeTimer = clock.schedule(NETWORK_STABILIZATION_MS) {
                send(SchedulerEvent.NetworkStabilized)
            }
        }
    }

    private fun handleNetworkStabilized() {
        TransferLog.i("network stabilized, requeuing waiting_network jobs")
        networkStabilizeTimer = null
        var requeuedCount = 0
        for ((jobId, job) in jobs) {
            if (job.state == JobState.WAITING_NETWORK) {
                if (JobState.validateAndLog(jobId, JobState.WAITING_NETWORK, JobState.QUEUED, "network_restored", job.retryCount)) {
                    job.state = JobState.QUEUED
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, JobState.QUEUED, job.retryCount, job.updatedAt)
                    emitStateChange(jobId, JobState.WAITING_NETWORK, JobState.QUEUED, "network_restored", job.retryCount)
                    requeuedCount++
                }
            }
        }
        if (requeuedCount > 0) {
            dispatchNext()
        }
    }

    private fun handleWorkerResult(jobId: String, result: WorkerResult) {
        runningWorkers.remove(jobId)
        val job = jobs[jobId] ?: return
        if (job.state != JobState.RUNNING) {
            return
        }

        when (result) {
            is WorkerResult.Success -> {
                // finishing → done
                if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.FINISHING, "transfer_complete", job.retryCount)) {
                    job.state = JobState.FINISHING
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, JobState.FINISHING, job.retryCount, job.updatedAt)
                    emitStateChange(jobId, JobState.RUNNING, JobState.FINISHING, "transfer_complete", job.retryCount)

                    if (JobState.validateAndLog(jobId, JobState.FINISHING, JobState.DONE, "finalized", job.retryCount)) {
                        job.state = JobState.DONE
                        job.updatedAt = clock.currentTimeMillis()
                        store.updateJobState(jobId, JobState.DONE, job.retryCount, job.updatedAt)
                        emitStateChange(jobId, JobState.FINISHING, JobState.DONE, "finalized", job.retryCount)
                    }
                }
            }
            is WorkerResult.NetworkError -> {
                // 网络类错误 → waiting_network，不计次数
                if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.WAITING_NETWORK, "network_error", job.retryCount)) {
                    job.state = JobState.WAITING_NETWORK
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, JobState.WAITING_NETWORK, job.retryCount, job.updatedAt)
                    emitStateChange(jobId, JobState.RUNNING, JobState.WAITING_NETWORK, "network_error", job.retryCount)
                }
            }
            is WorkerResult.StorageFull -> {
                // 空间不足 → storage_full
                if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.STORAGE_FULL, "storage_full", job.retryCount)) {
                    job.state = JobState.STORAGE_FULL
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, JobState.STORAGE_FULL, job.retryCount, job.updatedAt)
                    emitStateChange(jobId, JobState.RUNNING, JobState.STORAGE_FULL, "storage_full", job.retryCount)
                }
            }
            is WorkerResult.OtherError -> {
                // 其他错误按 5/15/30/60/120 秒重试，共 5 次，第 6 次用完进 interrupted
                if (job.retryCount < MAX_RETRIES) {
                    val delayMs = RETRY_DELAYS_MS[job.retryCount]
                    val attempt = job.retryCount + 1
                    job.retryCount = attempt
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, job.state, job.retryCount, job.updatedAt)

                    TransferLog.i("job=${TransferLog.shortId(jobId)} scheduled retry #$attempt in ${delayMs / 1000}s")

                    val timer = clock.schedule(delayMs) {
                        send(SchedulerEvent.RetryTimerFired(jobId, attempt))
                    }
                    pendingTimers[jobId] = timer
                } else {
                    // 第 6 次错误（5 次重试耗尽），进 interrupted
                    if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.INTERRUPTED, "max_retries_exceeded", job.retryCount)) {
                        job.state = JobState.INTERRUPTED
                        job.updatedAt = clock.currentTimeMillis()
                        store.updateJobState(jobId, JobState.INTERRUPTED, job.retryCount, job.updatedAt)
                        emitStateChange(jobId, JobState.RUNNING, JobState.INTERRUPTED, "max_retries_exceeded", job.retryCount)
                    }
                }
            }
        }

        dispatchNext()
    }

    private fun handleWorkerProgress(jobId: String, bytesRead: Long, totalBytes: Long) {
        val job = jobs[jobId] ?: return
        job.bytesRead = bytesRead
        job.totalBytes = totalBytes
        eventListener?.invoke(TransferEvent.Progress(jobId, bytesRead, totalBytes))
    }

    private fun handleRetryTimerFired(jobId: String, attempt: Int) {
        pendingTimers.remove(jobId)
        val job = jobs[jobId] ?: return
        if (job.state == JobState.RUNNING) {
            launchWorker(job)
        }
    }

    fun handleRestoreFromStore() {
        val recovered = store.recoverRunningJobs()
        val allStored = store.getAllJobs()
        for (stJob in allStored) {
            jobs[stJob.jobId] = stJob
        }
        for (job in recovered) {
            TransferLog.i("job=${TransferLog.shortId(job.jobId)} recovered from running to queued")
            emitStateChange(job.jobId, JobState.RUNNING, JobState.QUEUED, "process_kill_recovery", job.retryCount)
        }
        dispatchNext()
    }

    private fun handleServiceTimeout(reason: String) {
        TransferLog.i("Service timeout: $reason. Stopping all running jobs → interrupted")
        // 取消所有 Worker
        for ((jobId, workerJob) in runningWorkers) {
            workerJob.cancel(CancellationException("fgs_timeout"))
        }
        runningWorkers.clear()

        // 取消所有重试定时器
        for ((_, timer) in pendingTimers) {
            timer.cancel()
        }
        pendingTimers.clear()

        for ((jobId, job) in jobs) {
            if (job.state == JobState.RUNNING) {
                if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.INTERRUPTED, reason, job.retryCount)) {
                    job.state = JobState.INTERRUPTED
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, JobState.INTERRUPTED, job.retryCount, job.updatedAt)
                    emitStateChange(jobId, JobState.RUNNING, JobState.INTERRUPTED, reason, job.retryCount)
                }
            }
        }
    }

    fun dispatchNext() {
        var runningImages = jobs.values.count { it.state == JobState.RUNNING && it.category == JobCategory.IMAGE && runningWorkers.containsKey(it.jobId) }
        var runningLarge = jobs.values.count { it.state == JobState.RUNNING && it.category == JobCategory.LARGE_FILE && runningWorkers.containsKey(it.jobId) }

        // 分发图片类（并发上限 3）
        for ((jobId, job) in jobs) {
            if (runningImages >= MAX_CONCURRENT_IMAGES) break
            if (job.state == JobState.QUEUED && job.category == JobCategory.IMAGE) {
                if (JobState.validateAndLog(jobId, JobState.QUEUED, JobState.RUNNING, "dispatch", job.retryCount)) {
                    job.state = JobState.RUNNING
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, JobState.RUNNING, job.retryCount, job.updatedAt)
                    emitStateChange(jobId, JobState.QUEUED, JobState.RUNNING, "dispatch", job.retryCount)
                    launchWorker(job)
                    runningImages++
                }
            }
        }

        // 分发大文件类（并发上限 1）
        for ((jobId, job) in jobs) {
            if (runningLarge >= MAX_CONCURRENT_LARGE_FILES) break
            if (job.state == JobState.QUEUED && job.category == JobCategory.LARGE_FILE) {
                if (JobState.validateAndLog(jobId, JobState.QUEUED, JobState.RUNNING, "dispatch", job.retryCount)) {
                    job.state = JobState.RUNNING
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, JobState.RUNNING, job.retryCount, job.updatedAt)
                    emitStateChange(jobId, JobState.QUEUED, JobState.RUNNING, "dispatch", job.retryCount)
                    launchWorker(job)
                    runningLarge++
                }
            }
        }

        // 检查活跃任务数（queued / running / waiting_network / finishing）
        val activeCount = jobs.values.count {
            it.state == JobState.QUEUED ||
                it.state == JobState.RUNNING ||
                it.state == JobState.WAITING_NETWORK ||
                it.state == JobState.FINISHING
        }
        onIdleChanged?.invoke(activeCount == 0)
    }

    private fun launchWorker(job: TransferJob) {
        val worker = workerFactory(job)
        val workerJob = scope.launch {
            try {
                val result = worker.execute(job) { bytesRead, totalBytes ->
                    send(SchedulerEvent.WorkerProgressEvent(job.jobId, bytesRead, totalBytes))
                }
                send(SchedulerEvent.WorkerResultEvent(job.jobId, result))
            } catch (ce: CancellationException) {
                // 停止写入，不删除任何文件
                TransferLog.i("job=${TransferLog.shortId(job.jobId)} worker cancelled")
            } catch (t: Throwable) {
                send(SchedulerEvent.WorkerResultEvent(job.jobId, WorkerResult.OtherError(t.message ?: "unknown_error")))
            }
        }
        runningWorkers[job.jobId] = workerJob
    }

    private fun cancelWorker(jobId: String) {
        runningWorkers.remove(jobId)?.cancel(CancellationException("cancelled_by_scheduler"))
    }

    private fun emitStateChange(jobId: String, from: JobState, to: JobState, reason: String?, retryCount: Int) {
        eventListener?.invoke(TransferEvent.StateChanged(jobId, from, to, reason, retryCount))
    }

    fun onTimeout(reason: String = "fgs_timeout") {
        send(SchedulerEvent.ServiceTimeout(reason))
    }

    fun shutdown() {
        actorJob?.cancel()
        channel.close()
        for ((_, worker) in runningWorkers) {
            worker.cancel()
        }
        runningWorkers.clear()
        for ((_, timer) in pendingTimers) {
            timer.cancel()
        }
        pendingTimers.clear()
        networkStabilizeTimer?.cancel()
    }
}

