package com.james.easysave

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class HostServiceLifecycleTest {

    private class FakeResult : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
        override fun notImplemented() {}
    }

    private fun submitIntent(context: Context, mode: String = "select"): Intent {
        return Intent(context, HostService::class.java).apply {
            action = HostService.ACTION_SUBMIT
            putExtra(HostService.EXTRA_TEXT, "https://www.xiaohongshu.com/explore/abc123")
            putExtra(HostService.EXTRA_MODE, mode)
            putExtra(HostService.EXTRA_SOURCE, "bubble")
        }
    }

    @Test
    fun nullIntent_afterSystemRestart_stopsCleanlyWithoutStartingEngine() {
        val controller = Robolectric.buildService(HostService::class.java)
        val service = controller.create().get()
        var engineCreatedCount = 0
        service.testEngineFactory = { _ ->
            engineCreatedCount++
            object : HostService.TestEngineHandle {
                override fun sendSubmit(task: Map<String, Any?>) {}
                override fun destroy() {}
            }
        }

        service.onStartCommand(null, 0, 1)

        assertEquals(0, engineCreatedCount)
        assertEquals(HostService.EngineState.NONE, service.currentEngineStateForTesting())
        assertTrue(shadowOf(service).isStoppedBySelf)
    }

    @Test
    fun firstRequestAfterRestart_createsEngineOnDemandAndDispatchesWhenReady() {
        val controller = Robolectric.buildService(HostService::class.java)
        val service = controller.create().get()
        var dartHandler: MethodChannel.MethodCallHandler? = null
        val dispatched = mutableListOf<Map<String, Any?>>()

        service.testEngineFactory = { handler ->
            dartHandler = handler
            object : HostService.TestEngineHandle {
                override fun sendSubmit(task: Map<String, Any?>) {
                    dispatched.add(task)
                }

                override fun destroy() {}
            }
        }

        service.onStartCommand(null, 0, 1)
        assertEquals(HostService.EngineState.NONE, service.currentEngineStateForTesting())

        service.onStartCommand(submitIntent(service, mode = "select"), 0, 2)
        assertEquals(HostService.EngineState.STARTING, service.currentEngineStateForTesting())
        assertEquals(1, service.pendingCountForTesting())
        assertEquals(0, dispatched.size)

        dartHandler!!.onMethodCall(MethodCall("ready", null), FakeResult())

        assertEquals(HostService.EngineState.READY, service.currentEngineStateForTesting())
        assertEquals(0, service.pendingCountForTesting())
        assertEquals(1, dispatched.size)
        assertEquals("select", dispatched.single()["mode"])
    }

    @Test
    fun requestArrivingWhileReleasing_isQueuedAndDispatchedOnRebuiltEngine() {
        val controller = Robolectric.buildService(HostService::class.java)
        val service = controller.create().get()
        var engineCount = 0
        var latestHandler: MethodChannel.MethodCallHandler? = null
        val dispatched = mutableListOf<Map<String, Any?>>()

        service.testEngineFactory = { handler ->
            engineCount++
            latestHandler = handler
            object : HostService.TestEngineHandle {
                override fun sendSubmit(task: Map<String, Any?>) {
                    dispatched.add(task)
                }

                override fun destroy() {}
            }
        }

        service.simulateReleasingDuringActionForTesting {
            service.onStartCommand(submitIntent(service, mode = "select"), 0, 1)
            assertEquals(0, dispatched.size)
            assertEquals(1, service.pendingCountForTesting())
        }

        assertEquals(1, engineCount)
        assertEquals(HostService.EngineState.STARTING, service.currentEngineStateForTesting())

        latestHandler!!.onMethodCall(MethodCall("ready", null), FakeResult())

        assertEquals(HostService.EngineState.READY, service.currentEngineStateForTesting())
        assertEquals(1, dispatched.size)
        assertEquals("select", dispatched.single()["mode"])
    }

    @Test
    fun parseStallWatchdog_after30sWithoutParseStarted_updatesNotificationAndRebuildsEngine() {
        val controller = Robolectric.buildService(HostService::class.java)
        val service = controller.create().get()
        var engineCount = 0
        var destroyedCount = 0
        var latestHandler: MethodChannel.MethodCallHandler? = null

        service.testEngineFactory = { handler ->
            engineCount++
            latestHandler = handler
            object : HostService.TestEngineHandle {
                override fun sendSubmit(task: Map<String, Any?>) {}
                override fun destroy() {
                    destroyedCount++
                }
            }
        }

        service.onStartCommand(submitIntent(service, mode = "select"), 0, 1)
        latestHandler!!.onMethodCall(MethodCall("ready", null), FakeResult())
        latestHandler!!.onMethodCall(MethodCall("notify", "正在解析…"), FakeResult())

        shadowOf(Looper.getMainLooper()).idleFor(HostService.PARSE_STALL_TIMEOUT_MS + 100, TimeUnit.MILLISECONDS)

        assertEquals(1, destroyedCount)
        assertEquals(2, engineCount)
        assertEquals(HostService.EngineState.STARTING, service.currentEngineStateForTesting())

        val nm = service.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notifications = shadowOf(nm).allNotifications
        assertTrue(notifications.any {
            val extras = it.extras
            val title = extras.getCharSequence("android.title")?.toString() ?: ""
            val text = extras.getCharSequence("android.text")?.toString() ?: ""
            title.contains("解析失败") || text.contains("解析失败")
        })
    }
}

