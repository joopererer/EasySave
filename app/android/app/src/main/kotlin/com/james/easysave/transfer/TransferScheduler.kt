package com.james.easysave.transfer

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
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
    data class NetworkChanged(val isAvailable: Boolean, val wasOffline: Boolean = true) : SchedulerEvent()
    object NetworkStabilized : SchedulerEvent()
    data class WorkerResultEvent(val jobId: String, val result: WorkerResult) : SchedulerEvent()
    data class WorkerProgressEvent(val jobId: String, val bytesRead: Long, val totalBytes: Long) : SchedulerEvent()
    data class RetryTimerFired(val jobId: String, val attempt: Int) : SchedulerEvent()
    data class NetworkErrorResolved(val jobId: String, val error: String) : SchedulerEvent()
    object RestoreFromStore : SchedulerEvent()
    data class ServiceTimeout(val reason: String = "fgs_timeout") : SchedulerEvent()
    data class GetSnapshot(val callback: (List<TransferJob>) -> Unit) : SchedulerEvent()
    data class ClearJobsByBatch(val batchId: String, val callback: () -> Unit) : SchedulerEvent()
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
 * 线程要求：
 * - actor 运行在专用单线程（例如 Executors.newSingleThreadExecutor().asCoroutineDispatcher()）；
 * - Worker 运行在 Dispatchers.IO，均不得占用主线程。
 *
 * 并发上限：
 * - 图片类（IMAGE）：3
 * - 大文件类（LARGE_FILE）：1
 *
 * 重试策略（2026-11-23 修订）：
 * - Worker 报网络错误时，先查当前默认网络是否有 NET_CAPABILITY_VALIDATED：
 *   * 无可用网络：进入 waiting_network，不计次；
 *   * 网络可用：按「其他错误」处理，计次，按 5/15/30/60/120 秒退避，用完转 interrupted；
 * - waiting_network 的任务只在网络从「无可用」变为「可用并稳定 3 秒」时重新排队；初次注册时系统立即回调的 onAvailable 若之前并没有断网，不算恢复；
 * - 其他错误：按 5/15/30/60/120 秒重试 5 次，用完进 interrupted；
 * - 空间不足：storage_full。
 */
class TransferScheduler(
    val store: TransferStore,
    val workerFactory: (TransferJob) -> TransferWorker = { FakeWorker() },
    val scope: CoroutineScope,
    clock: TransferClock? = null,
    actorDispatcher: CoroutineDispatcher? = null,
    val networkChecker: NetworkCapabilityChecker = object : NetworkCapabilityChecker {
        override fun isDefaultNetworkValidated(): Boolean = true
    },
    val eventListener: ((TransferEvent) -> Unit)? = null,
    val onIdleChanged: ((isIdle: Boolean) -> Unit)? = null,
    val transfersDir: java.io.File? = null,
) {
    companion object {
        const val MAX_CONCURRENT_IMAGES = 3
        const val MAX_CONCURRENT_LARGE_FILES = 1
        const val NETWORK_STABILIZATION_MS = 3_000L
        const val NETWORK_ERROR_EVAL_DELAY_MS = 2_000L
        val RETRY_DELAYS_MS = longArrayOf(5_000L, 15_000L, 30_000L, 60_000L, 120_000L)
        const val MAX_RETRIES = 5
    }

    val clock: TransferClock = clock ?: CoroutineTransferClock(scope)

    private val defaultActorExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "Xfer-Actor-Thread").apply { isDaemon = true }
    }
    val actorDispatcher: CoroutineDispatcher = actorDispatcher ?: defaultActorExecutor.asCoroutineDispatcher()

    private val channel = Channel<SchedulerEvent>(Channel.UNLIMITED)

    // 内存中的任务镜像
    val jobs = LinkedHashMap<String, TransferJob>()

    // 运行中的 Worker 协程 Handle
    private val runningWorkers = ConcurrentHashMap<String, Job>()

    // 挂起中的定时器
    private val pendingTimers = ConcurrentHashMap<String, CancellableTimer>()

    // 网络错误延迟判定定时器（等待 2 秒以充分接收断网回调）
    private val networkErrorTimers = ConcurrentHashMap<String, CancellableTimer>()

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
        actorJob = scope.launch(actorDispatcher) {
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
            is SchedulerEvent.NetworkChanged -> handleNetworkChanged(event.isAvailable, event.wasOffline)
            is SchedulerEvent.NetworkStabilized -> handleNetworkStabilized()
            is SchedulerEvent.WorkerResultEvent -> handleWorkerResult(event.jobId, event.result)
            is SchedulerEvent.WorkerProgressEvent -> handleWorkerProgress(event.jobId, event.bytesRead, event.totalBytes)
            is SchedulerEvent.RetryTimerFired -> handleRetryTimerFired(event.jobId, event.attempt)
            is SchedulerEvent.NetworkErrorResolved -> handleNetworkErrorResolved(event.jobId, event.error)
            is SchedulerEvent.RestoreFromStore -> handleRestoreFromStore()
            is SchedulerEvent.ServiceTimeout -> handleServiceTimeout(event.reason)
            is SchedulerEvent.GetSnapshot -> event.callback(jobs.values.map { it.copy() })
            is SchedulerEvent.ClearJobsByBatch -> handleClearJobsByBatch(event.batchId, event.callback)
            is SchedulerEvent.CustomEvent -> event.onHandled(event.id)
        }
    }

    private fun handleEnqueue(newJob: TransferJob) {
        val existing = jobs[newJob.jobId]
        if (existing != null) {
            if (!existing.state.isTerminal) {
                TransferLog.w("job=${TransferLog.shortId(newJob.jobId)} duplicate_enqueue state=${existing.state.value} rejected")
                return
            }
            // 已终态的任务，忽略重复入队
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
            networkErrorTimers.remove(jobId)?.cancel()
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
            networkErrorTimers.remove(jobId)?.cancel()
            if (JobState.validateAndLog(jobId, fromState, JobState.CANCELED, "user_cancel", job.retryCount)) {
                job.state = JobState.CANCELED
                job.updatedAt = clock.currentTimeMillis()
                store.updateJobState(jobId, JobState.CANCELED, job.retryCount, job.updatedAt)
                emitStateChange(jobId, fromState, JobState.CANCELED, "user_cancel", job.retryCount)
                // 仅用户取消才删除 .part 与 .meta
                transfersDir?.let { dir ->
                    java.io.File(dir, "$jobId.part").delete()
                    java.io.File(dir, "$jobId.meta").delete()
                }
                TransferParamsRegistry.remove(jobId)
                dispatchNext()
            }
        }
    }

    private fun handleRetry(jobId: String) {
        val job = jobs[jobId] ?: return
        val fromState = job.state
        if (fromState == JobState.INTERRUPTED || fromState == JobState.STORAGE_FULL || fromState == JobState.FAILED) {
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

    private fun handleNetworkChanged(isAvailable: Boolean, wasOffline: Boolean) {
        if (!isAvailable) {
            networkStabilizeTimer?.cancel()
            networkStabilizeTimer = null
            TransferLog.i("network disconnected")
        } else {
            if (!wasOffline) {
                // 初次注册或未断网时的可用事件，不算恢复
                TransferLog.i("network available but not recovered from offline -> ignore")
                return
            }
            networkStabilizeTimer?.cancel()
            TransferLog.i("network connected after offline, waiting 3s stabilization")
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
                // 先等待 2 秒（通过 clock 定时），给底层网络断开事件充分传播时间，再检查网络是否 VALIDATED
                networkErrorTimers.remove(jobId)?.cancel()
                val timer = clock.schedule(NETWORK_ERROR_EVAL_DELAY_MS) {
                    channel.trySend(SchedulerEvent.NetworkErrorResolved(jobId, result.error))
                }
                networkErrorTimers[jobId] = timer
            }
            is WorkerResult.StorageFull -> {
                if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.STORAGE_FULL, "storage_full", job.retryCount)) {
                    job.state = JobState.STORAGE_FULL
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, JobState.STORAGE_FULL, job.retryCount, job.updatedAt)
                    emitStateChange(jobId, JobState.RUNNING, JobState.STORAGE_FULL, "storage_full", job.retryCount)
                }
            }
            is WorkerResult.PolicyRejected -> {
                if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.FAILED, result.error, job.retryCount)) {
                    job.state = JobState.FAILED
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, JobState.FAILED, job.retryCount, job.updatedAt)
                    emitStateChange(jobId, JobState.RUNNING, JobState.FAILED, result.error, job.retryCount)
                }
            }
            is WorkerResult.UrlExpired -> {
                if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.INTERRUPTED, result.error, job.retryCount)) {
                    job.state = JobState.INTERRUPTED
                    job.updatedAt = clock.currentTimeMillis()
                    store.updateJobState(jobId, JobState.INTERRUPTED, job.retryCount, job.updatedAt)
                    emitStateChange(jobId, JobState.RUNNING, JobState.INTERRUPTED, result.error, job.retryCount)
                    eventListener?.invoke(TransferEvent.ReresolveRequired(jobId))
                }
            }
            is WorkerResult.OtherError -> {
                handleOtherError(jobId, job, result.error)
            }
        }

        dispatchNext()
    }

    private fun handleNetworkErrorResolved(jobId: String, error: String) {
        networkErrorTimers.remove(jobId)
        val job = jobs[jobId] ?: return
        if (job.state != JobState.RUNNING) return

        val isValidated = networkChecker.isDefaultNetworkValidated()
        if (!isValidated) {
            // 无可用网络：进入 waiting_network，不计次数
            if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.WAITING_NETWORK, "network_error", job.retryCount)) {
                job.state = JobState.WAITING_NETWORK
                job.updatedAt = clock.currentTimeMillis()
                store.updateJobState(jobId, JobState.WAITING_NETWORK, job.retryCount, job.updatedAt)
                emitStateChange(jobId, JobState.RUNNING, JobState.WAITING_NETWORK, "network_error", job.retryCount)
            }
        } else {
            // 网络可用但出现网络类错误：按「其他错误」处理，计次，退避
            handleOtherError(jobId, job, "network_error_while_validated")
        }
        dispatchNext()
    }

    private fun handleOtherError(jobId: String, job: TransferJob, reason: String) {
        if (job.retryCount < MAX_RETRIES) {
            val delayMs = RETRY_DELAYS_MS[job.retryCount]
            val attempt = job.retryCount + 1
            job.retryCount = attempt
            job.updatedAt = clock.currentTimeMillis()
            store.updateJobState(jobId, job.state, job.retryCount, job.updatedAt)

            TransferLog.i("job=${TransferLog.shortId(jobId)} scheduled retry #$attempt in ${delayMs / 1000}s (reason: $reason)")

            val timer = clock.schedule(delayMs) {
                send(SchedulerEvent.RetryTimerFired(jobId, attempt))
            }
            pendingTimers[jobId] = timer
        } else {
            // 第 6 次失败（5 次重试耗尽），进 interrupted
            if (JobState.validateAndLog(jobId, JobState.RUNNING, JobState.INTERRUPTED, "max_retries_exceeded", job.retryCount)) {
                job.state = JobState.INTERRUPTED
                job.updatedAt = clock.currentTimeMillis()
                store.updateJobState(jobId, JobState.INTERRUPTED, job.retryCount, job.updatedAt)
                emitStateChange(jobId, JobState.RUNNING, JobState.INTERRUPTED, "max_retries_exceeded", job.retryCount)
            }
        }
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
        for ((jobId, workerJob) in runningWorkers) {
            workerJob.cancel(CancellationException("fgs_timeout"))
        }
        runningWorkers.clear()

        for ((_, timer) in pendingTimers) {
            timer.cancel()
        }
        pendingTimers.clear()
        for ((_, timer) in networkErrorTimers) {
            timer.cancel()
        }
        networkErrorTimers.clear()

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

    private fun handleClearJobsByBatch(batchId: String, callback: () -> Unit) {
        val targets = jobs.values.filter { it.batchId == batchId }
        for (job in targets) {
            cancelWorker(job.jobId)
            pendingTimers.remove(job.jobId)?.cancel()
            networkErrorTimers.remove(job.jobId)?.cancel()
            jobs.remove(job.jobId)
            FakeWorkerRegistry.reset(job.jobId)
        }
        store.deleteJobsByBatch(batchId)
        TransferLog.i("cleared ${targets.size} jobs for batch=$batchId")
        dispatchNext()
        callback()
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
        // 保证 Worker 运行在 Dispatchers.IO，不占用主线程与 actor 线程
        val workerJob = scope.launch(Dispatchers.IO) {
            try {
                val result = worker.execute(job) { bytesRead, totalBytes ->
                    send(SchedulerEvent.WorkerProgressEvent(job.jobId, bytesRead, totalBytes))
                }
                send(SchedulerEvent.WorkerResultEvent(job.jobId, result))
            } catch (ce: CancellationException) {
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
        for ((_, timer) in networkErrorTimers) {
            timer.cancel()
        }
        networkErrorTimers.clear()
        networkStabilizeTimer?.cancel()
        defaultActorExecutor.shutdown()
    }
}
