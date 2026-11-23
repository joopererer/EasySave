package com.james.easysave.transfer

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

/**
 * 传输服务与 Flutter 交互通道。
 *
 * MethodChannel: "easysave/transfer"
 * EventChannel: "easysave/transfer/events"
 */
object TransferChannels {
    const val METHOD_CHANNEL_NAME = "easysave/transfer"
    const val EVENT_CHANNEL_NAME = "easysave/transfer/events"

    private val mainHandler = Handler(Looper.getMainLooper())
    private val eventSinks = CopyOnWriteArrayList<EventChannel.EventSink>()

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext

        // 1. MethodChannel
        MethodChannel(messenger, METHOD_CHANNEL_NAME).setMethodCallHandler { call, result ->
            handleMethodCall(appContext, call, result)
        }

        // 2. EventChannel
        EventChannel(messenger, EVENT_CHANNEL_NAME).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                if (events != null) {
                    eventSinks.add(events)
                }
            }

            override fun onCancel(arguments: Any?) {
                // EventChannel can have only 1 active sink per channel instance
                eventSinks.clear()
            }
        })
    }

    private fun handleMethodCall(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val scheduler = TransferService.getOrCreateScheduler(context)

        when (call.method) {
            "enqueue" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val jobId = (args["jobId"] as? String)?.takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString()
                val direction = Direction.fromValue(args["direction"] as? String ?: "download")
                val category = JobCategory.fromValue(args["category"] as? String ?: "image")
                val batchId = args["batchId"] as? String
                val fakePlan = args["fakePlan"] as? String

                val job = TransferJob(
                    jobId = jobId,
                    direction = direction,
                    category = category,
                    batchId = batchId,
                    fakePlan = fakePlan
                )

                // 启动前台服务保活
                TransferService.startService(context)
                scheduler.send(SchedulerEvent.Enqueue(job))
                result.success(jobId)
            }
            "pause" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val jobId = args["jobId"] as? String
                if (jobId != null) {
                    scheduler.send(SchedulerEvent.Pause(jobId))
                    result.success(true)
                } else {
                    result.error("INVALID_ARGUMENT", "Missing jobId", null)
                }
            }
            "resume" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val jobId = args["jobId"] as? String
                if (jobId != null) {
                    TransferService.startService(context)
                    scheduler.send(SchedulerEvent.Resume(jobId))
                    result.success(true)
                } else {
                    result.error("INVALID_ARGUMENT", "Missing jobId", null)
                }
            }
            "cancel" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val jobId = args["jobId"] as? String
                if (jobId != null) {
                    scheduler.send(SchedulerEvent.Cancel(jobId))
                    result.success(true)
                } else {
                    result.error("INVALID_ARGUMENT", "Missing jobId", null)
                }
            }
            "retry" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val jobId = args["jobId"] as? String
                if (jobId != null) {
                    TransferService.startService(context)
                    scheduler.send(SchedulerEvent.Retry(jobId))
                    result.success(true)
                } else {
                    result.error("INVALID_ARGUMENT", "Missing jobId", null)
                }
            }
            "snapshot" -> {
                scheduler.send(SchedulerEvent.GetSnapshot { list ->
                    val data = list.map { it.toMap() }
                    mainHandler.post {
                        result.success(data)
                    }
                })
            }
            "simulateNetwork" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val isAvailable = args["isAvailable"] as? Boolean ?: true
                scheduler.send(SchedulerEvent.NetworkChanged(isAvailable))
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    fun broadcastEvent(event: TransferEvent) {
        val payload = when (event) {
            is TransferEvent.StateChanged -> event.toMap()
            is TransferEvent.Progress -> event.toMap()
        }
        mainHandler.post {
            for (sink in eventSinks) {
                try {
                    sink.success(payload)
                } catch (t: Throwable) {
                    eventSinks.remove(sink)
                }
            }
        }
    }
}

