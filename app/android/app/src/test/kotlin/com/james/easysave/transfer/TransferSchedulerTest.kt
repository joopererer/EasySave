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

    class TestNetworkChecker(var isValidated: Boolean = true) : NetworkCapabilityChecker {
        override fun isDefaultNetworkValidated(): Boolean = isValidated
    }

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("test_transfer.db")
        store = TransferStore(context, "test_transfer.db")
        testScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        FakeWorkerRegistry.reset()
        TransferNetworkMonitor.resetCounts()
    }

    @After
    fun tearDown() {
        store.close()
        context.deleteDatabase("test_transfer.db")
        FakeWorkerRegistry.reset()
        TransferNetworkMonitor.resetCounts()
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
                JobState.WAITING_PAIR,
                JobState.INTERRUPTED,
                JobState.STORAGE_FULL,
                JobState.FINISHING,
                JobState.FAILED,
                JobState.CANCELED
            ),
            JobState.PAUSED to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.WAITING_NETWORK to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.WAITING_PAIR to setOf(JobState.FINISHING, JobState.FAILED, JobState.CANCELED),
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
                JobState.WAITING_PAIR,
                JobState.INTERRUPTED,
                JobState.STORAGE_FULL,
                JobState.FINISHING,
                JobState.FAILED,
                JobState.CANCELED
            ),
            JobState.PAUSED to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.WAITING_NETWORK to setOf(JobState.QUEUED, JobState.CANCELED),
            JobState.WAITING_PAIR to setOf(JobState.FINISHING, JobState.FAILED, JobState.CANCELED),
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
        assertFalse(JobState.canTransition(JobState.RUNNING, JobState.QUEUED))
        assertFalse(JobState.canTransition(JobState.QUEUED, JobState.DONE))
        assertFalse(JobState.canTransition(JobState.DONE, JobState.QUEUED))
        assertFalse(JobState.canTransition(JobState.FAILED, JobState.RUNNING))
        assertFalse(JobState.canTransition(JobState.CANCELED, JobState.QUEUED))
        assertTrue("Expected dozens of illegal combinations rejected", illegalCount > 50)
    }

    // 2. 串行：并发投递 1000 个混合事件，处理顺序与投递顺序一致，任何时刻只有一个处理者
    @Test
    fun testSerialActor_1000MixedEventsProcessedInOrderWithSingleProcessor() = runBlocking {
        val clock = TestTransferClock()
        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() },
            scope = testScope,
            clock = clock,
        )

        val totalEvents = 1000
        val handledList = CopyOnWriteArrayList<Int>()
        val allDone = CompletableDeferred<Unit>()

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
        pollUntil { scheduler.activeProcessors.get() == 0 }

        assertEquals(totalEvents, handledList.size)
        assertEquals(1, scheduler.maxObservedConcurrency)
        assertEquals(0, scheduler.activeProcessors.get())

        scheduler.shutdown()
    }

    // 3. 并发上限：图片 3、大文件 1（经过工厂路径）
    @Test
    fun testConcurrencyLimit_images3_largeFiles1() = runBlocking {
        val activeImages = AtomicInteger(0)
        val activeLargeFiles = AtomicInteger(0)
        val maxImages = AtomicInteger(0)
        val maxLargeFiles = AtomicInteger(0)

        val gates = (1..8).associateWith { CompletableDeferred<Unit>() }

        for (i in 1..8) {
            val isImg = i <= 5
            val jobId = if (isImg) "img$i" else "large$i"
            FakeWorkerRegistry.registerCustomPlan(jobId) { job, _ ->
                if (isImg) {
                    val curr = activeImages.incrementAndGet()
                    synchronized(maxImages) { if (curr > maxImages.get()) maxImages.set(curr) }
                } else {
                    val curr = activeLargeFiles.incrementAndGet()
                    synchronized(maxLargeFiles) { if (curr > maxLargeFiles.get()) maxLargeFiles.set(curr) }
                }

                runBlocking {
                    gates[i]?.await()
                }

                if (isImg) {
                    activeImages.decrementAndGet()
                } else {
                    activeLargeFiles.decrementAndGet()
                }
                FakeWorker.FakePlan(WorkerResult.Success())
            }
        }

        val clock = TestTransferClock()
        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() }, // 严格使用工厂路径
            scope = testScope,
            clock = clock,
        )

        for (i in 1..5) {
            scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = "img$i", category = JobCategory.IMAGE)))
        }
        for (i in 6..8) {
            scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = "large$i", category = JobCategory.LARGE_FILE)))
        }

        pollUntil { activeImages.get() == 3 && activeLargeFiles.get() == 1 }

        assertEquals(3, activeImages.get())
        assertEquals(1, activeLargeFiles.get())
        assertEquals(3, maxImages.get())
        assertEquals(1, maxLargeFiles.get())

        gates[1]?.complete(Unit)
        pollUntil { scheduler.jobs["img1"]?.state == JobState.DONE }
        pollUntil { activeImages.get() == 3 }
        assertEquals(3, maxImages.get())

        gates[6]?.complete(Unit)
        pollUntil { scheduler.jobs["large6"]?.state == JobState.DONE }
        pollUntil { activeLargeFiles.get() == 1 }
        assertEquals(1, maxLargeFiles.get())

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

    // 4. 重试：网络错误在无网络时不计次进 waiting_network；其他错误按 5/15/30/60/120 秒重试 5 次，第 6 次进 interrupted
    @Test
    fun testRetry_networkErrorDoesNotIncrementCount_andOtherErrorsIntervalSequence() = runBlocking {
        val clock = TestTransferClock()
        val networkChecker = TestNetworkChecker(isValidated = false) // 模拟断网

        val netJob = TransferJob(jobId = "net_job", category = JobCategory.IMAGE, fakePlan = "network_once")

        var scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() }, // 严格使用工厂路径
            networkChecker = networkChecker,
            scope = testScope,
            clock = clock,
        )

        scheduler.send(SchedulerEvent.Enqueue(netJob))
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 2000L } }
        clock.advanceTimeBy(2000L)
        pollUntil { scheduler.jobs["net_job"]?.state == JobState.WAITING_NETWORK }

        assertEquals(JobState.WAITING_NETWORK, scheduler.jobs["net_job"]?.state)
        assertEquals(0, scheduler.jobs["net_job"]?.retryCount)

        // 模拟网络恢复为可用
        networkChecker.isValidated = true
        scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = true, wasOffline = true))
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 3000L } }

        clock.advanceTimeBy(3000L)
        pollUntil { scheduler.jobs["net_job"]?.state == JobState.DONE }
        assertEquals(JobState.DONE, scheduler.jobs["net_job"]?.state)
        assertEquals(0, scheduler.jobs["net_job"]?.retryCount)
        scheduler.shutdown()

        // 4.2 其他错误按 5/15/30/60/120 秒重试 5 次，第 6 次进 interrupted
        val otherJob = TransferJob(jobId = "other_job", category = JobCategory.IMAGE, fakePlan = "other_always")

        scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() }, // 工厂路径
            networkChecker = TestNetworkChecker(isValidated = true),
            scope = testScope,
            clock = clock,
        )

        val expectedDelays = listOf(5_000L, 15_000L, 30_000L, 60_000L, 120_000L)

        scheduler.send(SchedulerEvent.Enqueue(otherJob))

        for (i in 0 until 5) {
            val expectedDelay = expectedDelays[i]
            val expectedAttempt = i + 1

            pollUntil {
                clock.scheduledTasks.any { !it.isCancelled && it.delayMs == expectedDelay }
            }

            assertEquals(expectedAttempt, scheduler.jobs["other_job"]?.retryCount)
            assertEquals(JobState.RUNNING, scheduler.jobs["other_job"]?.state)

            clock.advanceTimeBy(expectedDelay)
        }

        pollUntil { scheduler.jobs["other_job"]?.state == JobState.INTERRUPTED }
        assertEquals(JobState.INTERRUPTED, scheduler.jobs["other_job"]?.state)
        assertEquals(5, scheduler.jobs["other_job"]?.retryCount)

        scheduler.shutdown()
    }

    // 5. 恢复：Store 里有 running 任务时重建服务，任务回到 queued 并能完成
    @Test
    fun testRecovery_runningJobsRestoredToQueuedAndCompleted() = runBlocking {
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
            workerFactory = { job -> FakeWorker() },
            scope = testScope,
            clock = clock,
        )

        scheduler.send(SchedulerEvent.RestoreFromStore)

        pollUntil { scheduler.jobs["killed_job_1"]?.state == JobState.DONE }
        assertEquals(JobState.DONE, store.getJob("killed_job_1")?.state)

        scheduler.shutdown()
    }

    // 6. onTimeout：所有 running 任务转 interrupted，原因 fgs_timeout
    @Test
    fun testOnTimeout_allRunningJobsTransitionToInterruptedWithReasonFgsTimeout() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        FakeWorkerRegistry.registerCustomPlan("timeout_job") { _, _ ->
            runBlocking { gate.await() }
            FakeWorker.FakePlan(WorkerResult.Success())
        }

        val clock = TestTransferClock()
        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() },
            scope = testScope,
            clock = clock,
        )

        val job = TransferJob(jobId = "timeout_job", category = JobCategory.IMAGE)
        scheduler.send(SchedulerEvent.Enqueue(job))

        pollUntil { scheduler.jobs["timeout_job"]?.state == JobState.RUNNING }

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
        val pauseGate = CompletableDeferred<Unit>()
        val resumeGate = CompletableDeferred<Unit>()
        FakeWorkerRegistry.registerCustomPlan("pause_resume_job_888") { _, attempt ->
            if (attempt == 0) {
                runBlocking { pauseGate.await() }
                FakeWorker.FakePlan(WorkerResult.Success())
            } else {
                runBlocking { resumeGate.await() }
                FakeWorker.FakePlan(WorkerResult.Success())
            }
        }

        val clock = TestTransferClock()
        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() },
            scope = testScope,
            clock = clock,
        )

        val targetJobId = "pause_resume_job_888"
        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = targetJobId, category = JobCategory.IMAGE)))

        pollUntil { scheduler.jobs[targetJobId]?.state == JobState.RUNNING }

        scheduler.send(SchedulerEvent.Pause(targetJobId))
        pollUntil { scheduler.jobs[targetJobId]?.state == JobState.PAUSED }
        assertEquals(JobState.PAUSED, store.getJob(targetJobId)?.state)
        pauseGate.complete(Unit)

        scheduler.send(SchedulerEvent.Resume(targetJobId))
        pollUntil { scheduler.jobs[targetJobId]?.state == JobState.RUNNING }

        resumeGate.complete(Unit)
        pollUntil { scheduler.jobs[targetJobId]?.state == JobState.DONE }
        assertEquals(JobState.DONE, store.getJob(targetJobId)?.state)

        val allStored = store.getAllJobs()
        assertEquals(1, allStored.size)
        assertEquals(targetJobId, allStored.first().jobId)

        scheduler.shutdown()
    }

    // --- P0-1b 新增单元测试 ---

    // 8. 新增测试：网络可用时的网络错误计次并退避，不进 waiting_network
    @Test
    fun testNetworkErrorWhileValidated_incrementsRetryAndBackoff_doesNotEnterWaitingNetwork() = runBlocking {
        val clock = TestTransferClock()
        val networkChecker = TestNetworkChecker(isValidated = true) // 网络已验证可用

        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() },
            networkChecker = networkChecker,
            scope = testScope,
            clock = clock,
        )

        val job = TransferJob(jobId = "validated_net_err_job", category = JobCategory.IMAGE, fakePlan = "network_always")
        scheduler.send(SchedulerEvent.Enqueue(job))

        // 轮询直到产生了 2000ms 的网络判定定时器
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 2000L } }
        clock.advanceTimeBy(2000L)

        // 轮询直到产生了重试定时器（首轮 5000ms）
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 5000L } }

        val currentJob = scheduler.jobs["validated_net_err_job"]
        assertNotNull(currentJob)
        // 验证没有进入 waiting_network，而是按其他错误处理
        assertEquals(JobState.RUNNING, currentJob?.state)
        assertEquals(1, currentJob?.retryCount)

        scheduler.shutdown()
    }

    // 9. 新增测试：网络回调从可用到可用不唤醒，从不可用到可用才唤醒
    @Test
    fun testNetworkCallback_availableToAvailableDoesNotWake_offlineAvailableWakes() = runBlocking {
        val clock = TestTransferClock()
        val networkChecker = TestNetworkChecker(isValidated = true) // 初始可用

        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() },
            networkChecker = networkChecker,
            scope = testScope,
            clock = clock,
        )

        val monitor = TransferNetworkMonitor(context, scheduler, networkChecker)
        monitor.start()

        // 验证初始状态 wasOffline 为 false
        assertFalse(monitor.wasOffline)

        // 模拟一个处于 WAITING_NETWORK 的任务
        val waitJob = TransferJob(jobId = "waiting_job", state = JobState.WAITING_NETWORK, category = JobCategory.IMAGE)
        store.insertOrReplace(waitJob)
        scheduler.jobs["waiting_job"] = waitJob

        // 网络变动但仍可用（可用到可用）：不应调度 3 秒唤醒
        monitor.checkAndDispatch()
        assertFalse(clock.scheduledTasks.any { it.delayMs == 3000L })
        assertEquals(JobState.WAITING_NETWORK, scheduler.jobs["waiting_job"]?.state)

        // 网络变为不可用
        networkChecker.isValidated = false
        monitor.checkAndDispatch()
        assertTrue(monitor.wasOffline)

        // 网络从不可用变为可用：必须调度 3 秒稳定唤醒
        networkChecker.isValidated = true
        monitor.checkAndDispatch()
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 3000L } }

        // 推进 3 秒时钟，任务成功被唤醒回到 QUEUED 并执行至 DONE
        clock.advanceTimeBy(3000L)
        pollUntil { scheduler.jobs["waiting_job"]?.state == JobState.DONE }
        assertEquals(JobState.DONE, scheduler.jobs["waiting_job"]?.state)

        monitor.stop()
        scheduler.shutdown()
    }

    // 10. 新增测试：回调只注册一次
    @Test
    fun testNetworkCallback_registeredOnlyOnce() {
        val clock = TestTransferClock()
        val scheduler = TransferScheduler(store = store, scope = testScope, clock = clock)
        val monitor = TransferNetworkMonitor(context, scheduler, TestNetworkChecker())

        assertEquals(0, TransferNetworkMonitor.totalRegisterCount.get())
        monitor.start()
        assertEquals(1, TransferNetworkMonitor.totalRegisterCount.get())

        // 重复调用 start 不会再次注册
        monitor.start()
        assertEquals(1, TransferNetworkMonitor.totalRegisterCount.get())

        monitor.stop()
        assertEquals(1, TransferNetworkMonitor.totalUnregisterCount.get())

        monitor.stop()
        assertEquals(1, TransferNetworkMonitor.totalUnregisterCount.get())

        scheduler.shutdown()
    }

    // 11. 新增测试：重复 jobId 入队被拒绝
    @Test
    fun testDuplicateEnqueue_rejectedAndLogged() = runBlocking {
        val clock = TestTransferClock()
        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() },
            scope = testScope,
            clock = clock,
        )

        val gate = CompletableDeferred<Unit>()
        FakeWorkerRegistry.registerCustomPlan("dup_job_1") { _, _ ->
            runBlocking { gate.await() }
            FakeWorker.FakePlan(WorkerResult.Success())
        }

        val job = TransferJob(jobId = "dup_job_1", category = JobCategory.IMAGE, batchId = "batch_original")
        scheduler.send(SchedulerEvent.Enqueue(job))
        pollUntil { scheduler.jobs["dup_job_1"]?.state == JobState.RUNNING }

        // 重复入队同一未终态任务
        val duplicateJob = TransferJob(jobId = "dup_job_1", category = JobCategory.LARGE_FILE, batchId = "batch_tampered")
        scheduler.send(SchedulerEvent.Enqueue(duplicateJob))

        // 验证任务没有被篡改覆盖
        assertEquals("batch_original", scheduler.jobs["dup_job_1"]?.batchId)
        assertEquals(JobCategory.IMAGE, scheduler.jobs["dup_job_1"]?.category)

        gate.complete(Unit)
        pollUntil { scheduler.jobs["dup_job_1"]?.state == JobState.DONE }

        scheduler.shutdown()
    }

    // 12. 新增测试：通过工厂路径跑自检三场景，全部到 done
    @Test
    fun testSelfCheckThreeScenarios_viaWorkerFactory_allReachDone() = runBlocking {
        val clock = TestTransferClock()
        val networkChecker = TestNetworkChecker(isValidated = false) // 初始断网以触发网络错误进 waiting_network

        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() }, // 纯工厂路径，每次调用均为新建实例
            networkChecker = networkChecker,
            scope = testScope,
            clock = clock,
        )

        val ts = "p0_1b_test"
        val job1Id = "job1_ok_$ts"
        val job2Id = "job2_net_$ts"
        val job3Id = "job3_ret_$ts"

        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = job1Id, category = JobCategory.IMAGE, fakePlan = "success")))
        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = job2Id, category = JobCategory.IMAGE, fakePlan = "network_once")))
        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = job3Id, category = JobCategory.LARGE_FILE, fakePlan = "other_twice")))

        // 任务 1 直接成功
        pollUntil { scheduler.jobs[job1Id]?.state == JobState.DONE }
        assertEquals(JobState.DONE, scheduler.jobs[job1Id]?.state)

        // 任务 2 首次报网络错误，等待 2 秒网络判定定时器推进后进入 waiting_network
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 2000L } }
        clock.advanceTimeBy(2000L)
        pollUntil { scheduler.jobs[job2Id]?.state == JobState.WAITING_NETWORK }
        assertEquals(JobState.WAITING_NETWORK, scheduler.jobs[job2Id]?.state)

        // 任务 3 大文件执行中，第 1 次失败，调度 5s 重试
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 5000L } }
        clock.advanceTimeBy(5000L)

        // 任务 3 第 2 次失败，调度 15s 重试
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 15000L } }
        clock.advanceTimeBy(15000L)

        // 任务 3 第 3 次成功完成
        pollUntil { scheduler.jobs[job3Id]?.state == JobState.DONE }
        assertEquals(JobState.DONE, scheduler.jobs[job3Id]?.state)

        // 此时网络恢复并稳定 3 秒，唤醒任务 2
        networkChecker.isValidated = true
        scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = true, wasOffline = true))
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 3000L } }
        clock.advanceTimeBy(3000L)

        // 任务 2 第二次运行通过工厂重建 FakeWorker，由于计数保存在注册表，成功完成
        pollUntil { scheduler.jobs[job2Id]?.state == JobState.DONE }
        assertEquals(JobState.DONE, scheduler.jobs[job2Id]?.state)

        // 验证 3 个任务全部到达 DONE 终态
        assertEquals(JobState.DONE, scheduler.jobs[job1Id]?.state)
        assertEquals(JobState.DONE, scheduler.jobs[job2Id]?.state)
        assertEquals(JobState.DONE, scheduler.jobs[job3Id]?.state)

        scheduler.shutdown()
    }

    // --- P0-2c 新增单元测试 ---

    // 14. 报错后 1 秒内网络回调报断开，任务进 waiting_network，不计次
    @Test
    fun testNetworkError_disconnectWithin1s_entersWaitingNetworkWithoutIncrementingRetry() = runBlocking {
        val clock = TestTransferClock()
        val networkChecker = TestNetworkChecker(isValidated = true) // 初始网络可用

        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() },
            networkChecker = networkChecker,
            scope = testScope,
            clock = clock,
        )

        val targetJobId = "disconnect_1s_job"
        val job = TransferJob(jobId = targetJobId, category = JobCategory.IMAGE, fakePlan = "network_always")
        scheduler.send(SchedulerEvent.Enqueue(job))

        // 轮询直到产生了 2000ms 的网络判定定时器（Worker 已报网络错误）
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 2000L } }

        // 报错后 1 秒内断网（飞行模式）
        networkChecker.isValidated = false
        scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = false, wasOffline = false))

        // 推进 2000ms 定时器
        clock.advanceTimeBy(2000L)

        // 任务必须进入 WAITING_NETWORK，且重试次数为 0（不计次）
        pollUntil { scheduler.jobs[targetJobId]?.state == JobState.WAITING_NETWORK }
        val currentJob = scheduler.jobs[targetJobId]
        assertEquals(JobState.WAITING_NETWORK, currentJob?.state)
        assertEquals(0, currentJob?.retryCount)

        scheduler.shutdown()
    }

    // 15. 连续 5 次「开飞行模式再关闭」不会进 interrupted
    @Test
    fun testFiveConsecutiveAirplaneModeCycles_neverEntersInterrupted() = runBlocking {
        val clock = TestTransferClock()
        val networkChecker = TestNetworkChecker(isValidated = true)

        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job -> FakeWorker() },
            networkChecker = networkChecker,
            scope = testScope,
            clock = clock,
        )

        val targetJobId = "airplane_5_cycles_job"
        val job = TransferJob(jobId = targetJobId, category = JobCategory.IMAGE, fakePlan = "network_always")
        scheduler.send(SchedulerEvent.Enqueue(job))

        for (cycle in 1..5) {
            // Worker 运行并报错，调度 2000ms 判定定时器
            pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 2000L } }

            // 1 秒内断开网络（开飞行模式）
            networkChecker.isValidated = false
            scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = false, wasOffline = false))

            // 推进 2000ms 定时器，任务进入 WAITING_NETWORK，重试次数保持为 0
            clock.advanceTimeBy(2000L)
            pollUntil { scheduler.jobs[targetJobId]?.state == JobState.WAITING_NETWORK }
            assertEquals(0, scheduler.jobs[targetJobId]?.retryCount)

            // 关闭飞行模式（网络恢复），调度 3 秒稳定唤醒
            networkChecker.isValidated = true
            scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = true, wasOffline = true))
            pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 3000L } }
            clock.advanceTimeBy(3000L)

            // 任务恢复到 RUNNING，准备进入下一轮
            pollUntil { scheduler.jobs[targetJobId]?.state == JobState.RUNNING }
            assertEquals(JobState.RUNNING, scheduler.jobs[targetJobId]?.state)
            assertEquals(0, scheduler.jobs[targetJobId]?.retryCount)
        }

        // 5 次飞行模式循环完毕后，验证从未进入 INTERRUPTED，且 retryCount 仍为 0
        assertFalse(scheduler.jobs[targetJobId]?.state == JobState.INTERRUPTED)
        assertEquals(0, scheduler.jobs[targetJobId]?.retryCount)

        scheduler.shutdown()
    }

    // 16. 连续 6 次「断网→恢复→立刻 DNS 失败（网络已 VALIDATED）」，retry 始终为 0，任务不进 interrupted
    @Test
    fun testSixConsecutiveDisconnectRestoreImmediateDnsFailure_retryAlwaysZeroAndNeverInterrupted() = runBlocking {
        val clock = TestTransferClock()
        val networkChecker = TestNetworkChecker(isValidated = true)

        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { _ -> FakeWorker() },
            networkChecker = networkChecker,
            scope = testScope,
            clock = clock,
        )

        val targetJobId = "dns_after_restore_6_cycles"
        val job = TransferJob(jobId = targetJobId, category = JobCategory.IMAGE, fakePlan = "network_always")
        scheduler.send(SchedulerEvent.Enqueue(job))

        for (cycle in 1..6) {
            // Worker 运行并报网络错误，调度 2000ms 判定定时器
            pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 2000L } }

            // 1. 断网
            networkChecker.isValidated = false
            scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = false, wasOffline = true))
            clock.advanceTimeBy(2000L)
            pollUntil { scheduler.jobs[targetJobId]?.state == JobState.WAITING_NETWORK }
            assertEquals(0, scheduler.jobs[targetJobId]?.retryCount)

            // 2. 恢复网络，3 秒稳定后立刻 dispatch
            networkChecker.isValidated = true
            scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = true, wasOffline = true))
            pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 3000L } }
            clock.advanceTimeBy(3000L)

            // 3. dispatch 后立刻 DNS 失败（此时网络已 VALIDATED，但距 network_restored 仅 2 秒 <= 15 秒）
            pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 2000L } }
            clock.advanceTimeBy(2000L)

            // 应不计次（retry 仍为 0），调度 5 秒后重试
            pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 5000L } }
            assertEquals(0, scheduler.jobs[targetJobId]?.retryCount)
            assertEquals(JobState.RUNNING, scheduler.jobs[targetJobId]?.state)

            // 推进 5 秒定时器，重新触发 Worker 进入下一轮
            clock.advanceTimeBy(5000L)
        }

        assertFalse(scheduler.jobs[targetJobId]?.state == JobState.INTERRUPTED)
        assertEquals(0, scheduler.jobs[targetJobId]?.retryCount)

        scheduler.shutdown()
    }

    // 17. 超过 15 秒后的网络错误（网络已 VALIDATED）仍按现有规则计次
    @Test
    fun testNetworkErrorAfter15sGraceWindow_incrementsRetry() = runBlocking {
        val clock = TestTransferClock()
        val networkChecker = TestNetworkChecker(isValidated = true)

        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { _ -> FakeWorker() },
            networkChecker = networkChecker,
            scope = testScope,
            clock = clock,
        )

        // 先触发一次网络变化并等待 actor 处理完毕，然后推进时间超过 15 秒
        val netApplied = CompletableDeferred<Unit>()
        scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = true, wasOffline = false))
        scheduler.send(SchedulerEvent.CustomEvent(1) { netApplied.complete(Unit) })
        netApplied.await()
        clock.advanceTimeBy(16_000L)

        val targetJobId = "after_grace_window_job"
        val job = TransferJob(jobId = targetJobId, category = JobCategory.IMAGE, fakePlan = "network_always")
        scheduler.send(SchedulerEvent.Enqueue(job))

        // Worker 报网络错误并等待 2000ms 判定
        pollUntil { clock.scheduledTasks.any { !it.isCancelled && it.delayMs == 2000L } }
        clock.advanceTimeBy(2000L)

        // 超过 15 秒，应计次为 retry #1 并调度 5 秒退避
        pollUntil { scheduler.jobs[targetJobId]?.retryCount == 1 }
        assertEquals(1, scheduler.jobs[targetJobId]?.retryCount)
        assertEquals(JobState.RUNNING, scheduler.jobs[targetJobId]?.state)

        scheduler.shutdown()
    }

    // 18. Live 图成对收尾：两个都完成才一起进入收尾
    @Test
    fun testLivePair_bothCompleteBeforeFinalizing() = runBlocking {
        val publisher = FakeMediaPublisher()
        val transfersDir = java.io.File(context.filesDir, "transfers_pair_test1").apply { mkdirs() }
        val finalizer = TransferFinalizer(transfersDir, store, publisher)
        val pairId = "post123#1"

        val imgGate = CompletableDeferred<Unit>()
        val vidGate = CompletableDeferred<Unit>()

        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job ->
                object : TransferWorker {
                    override suspend fun execute(job: TransferJob, onProgress: suspend (Long, Long) -> Unit): WorkerResult {
                        if (job.jobId == "live_img_1") imgGate.await() else vidGate.await()
                        return WorkerResult.Success()
                    }
                }
            },
            scope = testScope,
            transfersDir = transfersDir,
            finalizer = finalizer,
        )

        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = "live_img_1", pairId = pairId, category = JobCategory.IMAGE)))
        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = "live_vid_1", pairId = pairId, category = JobCategory.LARGE_FILE)))

        pollUntil { scheduler.jobs["live_img_1"]?.state == JobState.RUNNING && scheduler.jobs["live_vid_1"]?.state == JobState.RUNNING }

        // 先完成图片：应进入 WAITING_PAIR，不触发收尾
        imgGate.complete(Unit)
        pollUntil { scheduler.jobs["live_img_1"]?.state == JobState.WAITING_PAIR }
        assertEquals(0, publisher.entries.size)

        // 再完成视频：两者一起进入 FINISHING 并完成 DONE
        vidGate.complete(Unit)
        pollUntil {
            scheduler.jobs["live_img_1"]?.state == JobState.DONE &&
                scheduler.jobs["live_vid_1"]?.state == JobState.DONE
        }
        assertEquals(2, publisher.entries.size)
        scheduler.shutdown()
        transfersDir.deleteRecursively()
        Unit
    }

    // 19. Live 图成对收尾：一个失败，另一个不进相册
    @Test
    fun testLivePair_oneFails_otherDoesNotEnterAlbum() = runBlocking {
        val publisher = FakeMediaPublisher()
        val transfersDir = java.io.File(context.filesDir, "transfers_pair_test2").apply { mkdirs() }
        val finalizer = TransferFinalizer(transfersDir, store, publisher)
        val pairId = "post123#2"

        val imgGate = CompletableDeferred<Unit>()
        val vidGate = CompletableDeferred<Unit>()

        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job ->
                object : TransferWorker {
                    override suspend fun execute(job: TransferJob, onProgress: suspend (Long, Long) -> Unit): WorkerResult {
                        if (job.jobId == "live_img_2") {
                            imgGate.await()
                            return WorkerResult.Success()
                        } else {
                            vidGate.await()
                            return WorkerResult.PolicyRejected("403_forbidden")
                        }
                    }
                }
            },
            scope = testScope,
            transfersDir = transfersDir,
            finalizer = finalizer,
        )

        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = "live_img_2", pairId = pairId, category = JobCategory.IMAGE)))
        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = "live_vid_2", pairId = pairId, category = JobCategory.LARGE_FILE)))

        pollUntil { scheduler.jobs["live_img_2"]?.state == JobState.RUNNING && scheduler.jobs["live_vid_2"]?.state == JobState.RUNNING }

        imgGate.complete(Unit)
        pollUntil { scheduler.jobs["live_img_2"]?.state == JobState.WAITING_PAIR }
        assertEquals(0, publisher.entries.size)

        vidGate.complete(Unit)
        pollUntil {
            scheduler.jobs["live_img_2"]?.state == JobState.FAILED &&
                scheduler.jobs["live_vid_2"]?.state == JobState.FAILED
        }
        assertEquals(0, publisher.entries.size)
        scheduler.shutdown()
        transfersDir.deleteRecursively()
        Unit
    }

    // 20. Live 图成对收尾：暂停其中一个，另一个下载完成后等待配对，不单独收尾
    @Test
    fun testLivePair_pauseOne_otherWaitsForPair_thenCompletesOnResume() = runBlocking {
        val publisher = FakeMediaPublisher()
        val transfersDir = java.io.File(context.filesDir, "transfers_pair_test3").apply { mkdirs() }
        val finalizer = TransferFinalizer(transfersDir, store, publisher)
        val pairId = "post123#3"

        val imgGate = CompletableDeferred<Unit>()
        val vidGate = CompletableDeferred<Unit>()

        val scheduler = TransferScheduler(
            store = store,
            workerFactory = { job ->
                object : TransferWorker {
                    override suspend fun execute(job: TransferJob, onProgress: suspend (Long, Long) -> Unit): WorkerResult {
                        if (job.jobId == "live_img_3") imgGate.await() else vidGate.await()
                        return WorkerResult.Success()
                    }
                }
            },
            scope = testScope,
            transfersDir = transfersDir,
            finalizer = finalizer,
        )

        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = "live_img_3", pairId = pairId, category = JobCategory.IMAGE)))
        scheduler.send(SchedulerEvent.Enqueue(TransferJob(jobId = "live_vid_3", pairId = pairId, category = JobCategory.LARGE_FILE)))

        pollUntil { scheduler.jobs["live_img_3"]?.state == JobState.RUNNING && scheduler.jobs["live_vid_3"]?.state == JobState.RUNNING }

        // 暂停视频
        scheduler.send(SchedulerEvent.Pause("live_vid_3"))
        pollUntil { scheduler.jobs["live_vid_3"]?.state == JobState.PAUSED }

        // 图片完成：应停在 WAITING_PAIR，不单独收尾
        imgGate.complete(Unit)
        pollUntil { scheduler.jobs["live_img_3"]?.state == JobState.WAITING_PAIR }
        assertEquals(0, publisher.entries.size)

        // 恢复视频并完成：两者一起收尾成功
        scheduler.send(SchedulerEvent.Resume("live_vid_3"))
        pollUntil { scheduler.jobs["live_vid_3"]?.state == JobState.RUNNING }
        vidGate.complete(Unit)
        pollUntil {
            scheduler.jobs["live_img_3"]?.state == JobState.DONE &&
                scheduler.jobs["live_vid_3"]?.state == JobState.DONE
        }
        assertEquals(2, publisher.entries.size)
        scheduler.shutdown()
        transfersDir.deleteRecursively()
        Unit
    }
}
