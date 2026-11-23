package com.james.easysave.transfer

import android.content.Context
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * 传输服务与调度器核心测试（JVM 单元测试，等待一律用轮询或 await，不用固定 sleep）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@OptIn(ExperimentalCoroutinesApi::class)
class TransferSchedulerTest {

    private lateinit var context: Context
    private lateinit var store: TransferStore
    private lateinit var testScope: CoroutineScope

    class TestTransferClock : TransferClock {
        var currentTime: Long = 1000000L
        val scheduledTasks = CopyOnWriteArrayList<ScheduledTask>()

        data class ScheduledTask(
            val triggerTime: Long,
            val delayMs: Long,
            val action: () -> Unit,
            var isCancelled: Boolean = false,
        )

        override fun currentTimeMillis(): Long = currentTime

        override fun schedule(delayMs: Long, action: () -> Unit): CancellableTimer {
            val task = ScheduledTask(currentTime + delayMs, delayMs, action)
            scheduledTasks.add(task)
            return object : CancellableTimer {
                override fun cancel() {
                    task.isCancelled = true
                }
            }
        }

        fun advanceTimeBy(ms: Long) {
            currentTime += ms
            val iterator = scheduledTasks.iterator()
            val toRun = mutableListOf<ScheduledTask>()
            while (iterator.hasNext()) {
                val t = iterator.next()
                if (!t.isCancelled && t.triggerTime <= currentTime) {
                    toRun.add(t)
                }
            }
            scheduledTasks.removeAll(toRun)
            for (t in toRun) {
                t.action()
            }
        }
    }

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("test_transfer.db")
        store = TransferStore(context, "test_transfer.db")
        testScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }

    @After
    fun tearDown() {
        store.close()
        context.deleteDatabase("test_transfer.db")
    }

    private suspend fun pollUntil(
        timeoutMs: Long = 5000L,
        intervalMs: Long = 10L,
        condition: () -> Boolean,
    ) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            delay(intervalMs)
        }
        throw AssertionError("pollUntil timed out after ${timeoutMs}ms")
    }

    // 1. 转移表：每个合法转移通过、每类非法转移被拒绝
    @Test
    fun testTransitionTable_allLegalTransitionsAllowed() {
        val legalTransitions = mapOf(
            JobState.QUEUED to setOf(JobState.RUNNING, JobState.CANCELED),
            JobState.RUNNING to setOf(
                JobState.PAUSED,
                JobState.WAITING_NETWORK,
                JobState.INTERRUPTED,
                JobState.STORAGE_FULL,
                JobState.FINISHING,
                JobState.FAILED,
                JobState.CANCELED
            ),
            JobState.PAUSED to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.WAITING_NETWORK to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.INTERRUPTED to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.STORAGE_FULL to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.FINISHING to setOf(JobState.DONE, JobState.FAILED, JobState.CANCELED),
            JobState.DONE to emptySet(),
            JobState.FAILED to emptySet(),
            JobState.CANCELED to emptySet(),
        )

        for ((from, targetSet) in legalTransitions) {
            for (to in targetSet) {
                assertTrue("Expected legal transition $from -> $to", JobState.canTransition(from, to))
                assertTrue(
                    "validateAndLog should return true for $from -> $to",
                    JobState.validateAndLog("job_legal", from, to, "test_legal")
                )
            }
        }
    }

    @Test
    fun testTransitionTable_allIllegalTransitionsRejected() {
        val allStates = JobState.entries

        val legalTransitions = mapOf(
            JobState.QUEUED to setOf(JobState.RUNNING, JobState.CANCELED),
            JobState.RUNNING to setOf(
                JobState.PAUSED,
                JobState.WAITING_NETWORK,
                JobState.INTERRUPTED,
                JobState.STORAGE_FULL,
                JobState.FINISHING,
                JobState.FAILED,
                JobState.CANCELED
            ),
            JobState.PAUSED to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.WAITING_NETWORK to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.INTERRUPTED to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.STORAGE_FULL to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.FINISHING to setOf(JobState.DONE, JobState.FAILED, JobState.CANCELED),
            JobState.DONE to emptySet(),
            JobState.FAILED to emptySet(),
            JobState.CANCELED to emptySet(),
        )

        var illegalCount = 0
        for (from in allStates) {
            val allowed = legalTransitions[from] ?: emptySet()
            for (to in allStates) {
                if (!allowed.contains(to)) {
                    assertFalse("Transition $from -> $to must be rejected", JobState.canTransition(from, to))
                    assertFalse(
                        "validateAndLog should return false for $from -> $to without throwing",
                        JobState.validateAndLog("job_illegal", from, to, "test_illegal")
                    )
                    illegalCount++
                }
            }
        }

        // 验证特定核心非法转移分类
        assertFalse(JobState.canTransition(JobState.RUNNING, JobState.QUEUED)) // running 不能直转 queued
        assertFalse(JobState.canTransition(JobState.QUEUED, JobState.DONE)) // queued 不能直转 done
        assertFalse(JobState.canTransition(JobState.DONE, JobState.QUEUED)) // 终态不能转 queued
        assertFalse(JobState.canTransition(JobState.FAILED, JobState.RUNNING)) // 终态不能转 running
        assertFalse(JobState.canTransition(JobState.CANCELED, JobState.QUEUED)) // 终态不能转 queued
        assertTrue("Expected dozens of illegal combinations rejected", illegalCount > 50)
    }

    // 2. 串行：并发投递 1000 个混合事件，处理顺序与投递顺序一致，任何时刻只有一个处理者
    @Test
    fun testSerialActor_1000MixedEventsProcessedInOrderWithSingleProcessor() = runBlocking {
        val clock = TestTransferClock()
        val scheduler = TransferScheduler(
            store = store,
            scope = testScope,
            clock = clock,
        )

        val totalEvents = 1000
        val handledList = CopyOnWriteArrayList<Int>()
        val allDone = CompletableDeferred<Unit>()

        // 10 个并发协程投递
        val coroutineCount = 10
        val perCoroutine = totalEvents / coroutineCount

        for (c in 0 until coroutineCount) {
            launch(Dispatchers.Default) {
                for (i in 0 until perCoroutine) {
                    val eventId = c * perCoroutine + i
                    scheduler.send(SchedulerEvent.CustomEvent(eventId) { id ->
                        handledList.add(id)
                        if (handledList.size == totalEvents) {
                            allDone.complete(Unit)
                        }
                    })
                }
            }
        }

        allDone.await()

        // 验证处理了 1000 个事件
        assertEquals(totalEvents, handledList.size)
        // 验证任何时刻只有一个处理者
        assertEquals(1, scheduler.maxObservedConcurrency)
        assertEquals(0, scheduler.activeProcessors.get())

        scheduler.shutdown()
    }

    // 3. 并发上限：图片 3、大文件 1
    @Test
    fun testConcurrencyLimit_images3_largeFiles1() = runBlocking {
        val activeImages = AtomicInteger(0)
        val activeLargeFiles = AtomicInteger(0)
        val maxImages = AtomicInteger(0)
        val maxLargeFiles = AtomicInteger(0)

        val gates = (1..8).associateWith { CompletableDeferred<Unit>() }

        val worker = object : TransferWorker {
            override suspend fun execute(
                job: TransferJob,
                onProgress: suspend (bytesRead: Long, totalBytes: Long) -> Unit
            ): WorkerResult {
                val index = job.jobId.filter { it.isDigit() }.toInt()
                if (job.category == JobCategory.IMAGE) {
                    val curr = activeImages.incrementAndGet()
                    synchronized(maxImages) {
                        if (curr > maxImages.get()) maxImages.set(curr)
                    }
                } else {
                    val curr = activeLargeFiles.incrementAndGet()
                    synchronized(maxLargeFiles) {
                        if (curr > maxLargeFiles.get()) maxLargeFiles.set(curr)
                    }
                }

                // 等待控制闸门放行
                gates[index]?.await()

                if (job.category == JobCategory.IMAGE) {
                    activeImages.decrementAndGet()
                } else {
                    activeLargeFiles.decrementAndGet()
                }
                return WorkerResult.Success()
            }
        }

        val clock = TestTransferClock()
        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { worker },
            scope = testScope,
            clock = clock,
        )

        // 入队 5 张图片（img1..img5）与 3 个大文件（large6..large8）
        for (i in 1..5) {
            scheduler.send(
                SchedulerEvent.Enqueue(
                    TransferJob(jobId = "img$i", category = JobCategory.IMAGE)
                )
            )
        }
        for (i in 6..8) {
            scheduler.send(
                SchedulerEvent.Enqueue(
                    TransferJob(jobId = "large$i", category = JobCategory.LARGE_FILE)
                )
            )
        }

        // 轮询等待调度分发
        pollUntil { activeImages.get() == 3 && activeLargeFiles.get() == 1 }

        // 验证并发上限：图片 3，大文件 1
        assertEquals(3, activeImages.get())
        assertEquals(1, activeLargeFiles.get())
        assertEquals(3, maxImages.get())
        assertEquals(1, maxLargeFiles.get())

        // 放行 1 张图片，后续图片应该补入，图片最大并发仍不超过 3
        gates[1]?.complete(Unit)
        pollUntil { scheduler.jobs["img1"]?.state == JobState.DONE }
        pollUntil { activeImages.get() == 3 }
        assertEquals(3, maxImages.get())

        // 放行 1 个大文件，后续大文件补入，大文件最大并发仍不超过 1
        gates[6]?.complete(Unit)
        pollUntil { scheduler.jobs["large6"]?.state == JobState.DONE }
        pollUntil { activeLargeFiles.get() == 1 }
        assertEquals(1, maxLargeFiles.get())

        // 全部放行
        for (i in 1..8) {
            gates[i]?.complete(Unit)
        }

        pollUntil {
            scheduler.jobs.values.all { it.state == JobState.DONE }
        }

        assertEquals(3, maxImages.get())
        assertEquals(1, maxLargeFiles.get())
        scheduler.shutdown()
    }

    // 4. 重试：网络错误不计次；其他错误的间隔序列为 5/15/30/60/120 且第 6 次进 interrupted（用可注入时钟，不真等）
    @Test
    fun testRetry_networkErrorDoesNotIncrementCount_andOtherErrorsIntervalSequence() = runBlocking {
        val clock = TestTransferClock()

        // 4.1 网络错误测试
        val netJob = TransferJob(jobId = "net_job", category = JobCategory.IMAGE)
        val netWorker = object : TransferWorker {
            var calls = 0
            override suspend fun execute(
                job: TransferJob,
                onProgress: suspend (bytesRead: Long, totalBytes: Long) -> Unit
            ): WorkerResult {
                calls++
                return if (calls == 1) {
                    WorkerResult.NetworkError("simulated_disconnect")
                } else {
                    WorkerResult.Success()
                }
            }
        }

        var scheduler = TransferScheduler(
            store = store,
            workerFactory = { netWorker },
            scope = testScope,
            clock = clock,
        )

        scheduler.send(SchedulerEvent.Enqueue(netJob))
        pollUntil { scheduler.jobs["net_job"]?.state == JobState.WAITING_NETWORK }

        // 验证网络错误不计重试次数
        assertEquals(JobState.WAITING_NETWORK, scheduler.jobs["net_job"]?.state)
        assertEquals(0, scheduler.jobs["net_job"]?.retryCount)

        // 模拟网络恢复，并验证稳定 3 秒后重新排队
        scheduler.send(SchedulerEvent.NetworkChanged(true))
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 3000L } }

        // 推进 3000ms 时钟
        clock.advanceTimeBy(3000L)
        pollUntil { scheduler.jobs["net_job"]?.state == JobState.DONE }
        assertEquals(JobState.DONE, scheduler.jobs["net_job"]?.state)
        assertEquals(0, scheduler.jobs["net_job"]?.retryCount)
        scheduler.shutdown()

        // 4.2 其他错误按 5/15/30/60/120 秒重试 5 次，第 6 次进 interrupted
        val otherJob = TransferJob(jobId = "other_job", category = JobCategory.IMAGE)
        val failWorker = object : TransferWorker {
            override suspend fun execute(
                job: TransferJob,
                onProgress: suspend (bytesRead: Long, totalBytes: Long) -> Unit
            ): WorkerResult {
                return WorkerResult.OtherError("http_500")
            }
        }

        scheduler = TransferScheduler(
            store = store,
            workerFactory = { failWorker },
            scope = testScope,
            clock = clock,
        )

        val expectedDelays = listOf(5_000L, 15_000L, 30_000L, 60_000L, 120_000L)

        scheduler.send(SchedulerEvent.Enqueue(otherJob))

        for (i in 0 until 5) {
            val expectedDelay = expectedDelays[i]
            val expectedAttempt = i + 1

            // 轮询直到产生了对应的定时重试任务
            pollUntil {
                clock.scheduledTasks.any { !it.isCancelled && it.delayMs == expectedDelay }
            }

            assertEquals(expectedAttempt, scheduler.jobs["other_job"]?.retryCount)
            assertEquals(JobState.RUNNING, scheduler.jobs["other_job"]?.state)

            // 虚拟时钟推进
            clock.advanceTimeBy(expectedDelay)
        }

        // 第 6 次失败（5 次重试耗尽），进 interrupted
        pollUntil { scheduler.jobs["other_job"]?.state == JobState.INTERRUPTED }
        assertEquals(JobState.INTERRUPTED, scheduler.jobs["other_job"]?.state)
        assertEquals(5, scheduler.jobs["other_job"]?.retryCount)

        scheduler.shutdown()
    }

    // 5. 恢复：Store 里有 running 任务时重建服务，任务回到 queued 并能完成
    @Test
    fun testRecovery_runningJobsRestoredToQueuedAndCompleted() = runBlocking {
        // 在 Store 中预置 running 任务（模拟进程被杀）
        val killedJob = TransferJob(
            jobId = "killed_job_1",
            state = JobState.RUNNING,
            category = JobCategory.IMAGE,
            retryCount = 1
        )
        store.insertOrReplace(killedJob)

        assertEquals(JobState.RUNNING, store.getJob("killed_job_1")?.state)

        val clock = TestTransferClock()
        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { FakeWorker() },
            scope = testScope,
            clock = clock,
        )

        // 触发服务重建恢复逻辑
        scheduler.send(SchedulerEvent.RestoreFromStore)

        // 轮询验证恢复为 queued 并最终执行到 DONE
        pollUntil { scheduler.jobs["killed_job_1"]?.state == JobState.DONE }
        assertEquals(JobState.DONE, store.getJob("killed_job_1")?.state)

        scheduler.shutdown()
    }

    // 6. onTimeout：所有 running 任务转 interrupted，原因 fgs_timeout
    @Test
    fun testOnTimeout_allRunningJobsTransitionToInterruptedWithReasonFgsTimeout() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val blockingWorker = object : TransferWorker {
            override suspend fun execute(
                job: TransferJob,
                onProgress: suspend (bytesRead: Long, totalBytes: Long) -> Unit
            ): WorkerResult {
                gate.await()
                return WorkerResult.Success()
            }
        }

        val clock = TestTransferClock()
        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { blockingWorker },
            scope = testScope,
            clock = clock,
        )

        val job = TransferJob(jobId = "timeout_job", category = JobCategory.IMAGE)
        scheduler.send(SchedulerEvent.Enqueue(job))

        pollUntil { scheduler.jobs["timeout_job"]?.state == JobState.RUNNING }

        // 触发 onTimeout
        scheduler.onTimeout("fgs_timeout")

        pollUntil { scheduler.jobs["timeout_job"]?.state == JobState.INTERRUPTED }
        assertEquals(JobState.INTERRUPTED, scheduler.jobs["timeout_job"]?.state)
        assertEquals(JobState.INTERRUPTED, store.getJob("timeout_job")?.state)

        gate.complete(Unit)
        scheduler.shutdown()
    }

    // 7. 暂停→继续：同一 jobId，不新建任务
    @Test
    fun testPauseResume_sameJobIdNotRecreated() = runBlocking {
        val resumeGate = CompletableDeferred<Unit>()
        val controllableWorker = object : TransferWorker {
            var runCount = 0
            override suspend fun execute(
                job: TransferJob,
                onProgress: suspend (bytesRead: Long, totalBytes: Long) -> Unit
            ): WorkerResult {
                runCount++
                if (runCount == 1) {
                    // 第一次挂起等待暂停
                    delay(5000L)
                    return WorkerResult.Success()
                } else {
                    // 继续后等待闸门放行完成
                    resumeGate.await()
                    return WorkerResult.Success()
                }
            }
        }

        val clock = TestTransferClock()
        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { controllableWorker },
            scope = testScope,
            clock = clock,
        )

        val targetJobId = "pause_resume_job_888"
        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = targetJobId, category = JobCategory.IMAGE)))

        pollUntil { scheduler.jobs[targetJobId]?.state == JobState.RUNNING }

        // 暂停任务
        scheduler.send(SchedulerEvent.Pause(targetJobId))
        pollUntil { scheduler.jobs[targetJobId]?.state == JobState.PAUSED }
        assertEquals(JobState.PAUSED, store.getJob(targetJobId)?.state)

        // 继续同一任务
        scheduler.send(SchedulerEvent.Resume(targetJobId))
        pollUntil { scheduler.jobs[targetJobId]?.state == JobState.RUNNING }

        // 放行完成
        resumeGate.complete(Unit)
        pollUntil { scheduler.jobs[targetJobId]?.state == JobState.DONE }
        assertEquals(JobState.DONE, store.getJob(targetJobId)?.state)

        // 验证 Store 中自始至终只有一个任务，jobId 一致，没有新建任务
        val allStored = store.getAllJobs()
        assertEquals(1, allStored.size)
        assertEquals(targetJobId, allStored.first().jobId)

        scheduler.shutdown()
    }
}

