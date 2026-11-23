package com.james.easysave.transfer

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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
    private val channelScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

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

                if (batchId == "self_check_batch") {
                    MainThreadLagMonitor.start(channelScope)
                }

                val job = TransferJob(
                    jobId = jobId,
                    direction = direction,
                    category = category,
                    batchId = batchId,
                    fakePlan = fakePlan
                )

                val url = args["url"] as? String
                val headersRaw = (args["headers"] as? Map<*, *>) ?: emptyMap<Any?, Any?>()
                val headers = headersRaw.entries.associate { it.key.toString() to it.value.toString() }
                val cookie = args["cookie"] as? String
                val allowedCookieDomains = (args["allowedCookieDomains"] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
                val policyHostsRaw = (args["policyHosts"] as? List<*>)?.mapNotNull { it as? Map<*, *> } ?: emptyList()
                val policyHosts = policyHostsRaw.mapNotNull {
                    val domain = it["domain"] as? String ?: return@mapNotNull null
                    val includeSubdomains = (it["includeSubdomains"] as? Boolean) ?: false
                    com.james.easysave.policy.MediaPolicyRedirects.HostRule(domain, includeSubdomains)
                }
                val mime = args["mime"] as? String
                val policyKey = args["policyKey"] as? String

                if (!url.isNullOrBlank()) {
                    TransferParamsRegistry.set(
                        jobId,
                        TransferDownloadParams(
                            url = url,
                            headers = headers,
                            cookie = cookie,
                            allowedCookieDomains = allowedCookieDomains,
                            policyHosts = policyHosts,
                            mime = mime,
                            policyKey = policyKey,
                        )
                    )
                }

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
            "clearSelfCheckJobs" -> {
                scheduler.send(SchedulerEvent.ClearJobsByBatch("self_check_batch") {
                    MainThreadLagMonitor.stop()
                    mainHandler.post {
                        result.success(true)
                    }
                })
            }
            "simulateNetwork" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val isAvailable = args["isAvailable"] as? Boolean ?: true
                TransferService.sharedNetworkChecker?.simulatedValidated = isAvailable
                scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = isAvailable, wasOffline = true))
                result.success(true)
            }
            "getJobFileInfo" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val jobId = args["jobId"] as? String ?: ""
                val transfersDir = java.io.File(context.filesDir, "transfers")
                val partFile = java.io.File(transfersDir, "$jobId.part")
                if (!partFile.exists()) {
                    result.success(mapOf("exists" to false))
                } else {
                    val size = partFile.length()
                    val sha256 = try {
                        val md = java.security.MessageDigest.getInstance("SHA-256")
                        partFile.inputStream().use { stream ->
                            val buf = ByteArray(8192)
                            var read: Int
                            while (stream.read(buf).also { read = it } > 0) {
                                md.update(buf, 0, read)
                            }
                        }
                        md.digest().joinToString("") { "%02x".format(it) }
                    } catch (t: Throwable) {
                        "error: ${t.message}"
                    }
                    result.success(
                        mapOf(
                            "exists" to true,
                            "size" to size,
                            "sha256" to sha256,
                            "path" to partFile.absolutePath,
                        )
                    )
                }
            }
            "deleteJobFile" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val jobId = args["jobId"] as? String ?: ""
                val transfersDir = java.io.File(context.filesDir, "transfers")
                val partFile = java.io.File(transfersDir, "$jobId.part")
                val metaFile = java.io.File(transfersDir, "$jobId.meta")
                val d1 = partFile.delete()
                val d2 = metaFile.delete()
                TransferParamsRegistry.remove(jobId)
                result.success(d1 || d2 || !partFile.exists())
            }
            else -> result.notImplemented()
        }
    }

    fun broadcastEvent(event: TransferEvent) {
        val payload = when (event) {
            is TransferEvent.StateChanged -> event.toMap()
            is TransferEvent.Progress -> event.toMap()
            is TransferEvent.ReresolveRequired -> event.toMap()
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
