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
import kotlinx.coroutines.launch
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
                val provenanceRaw = args["provenance"] as? Map<*, *>
                val provenance = provenanceRaw?.let { raw ->
                    fun convert(m: Map<*, *>): Map<String, Any?> {
                        return m.entries.associate { (k, v) ->
                            k.toString() to when (v) {
                                is Map<*, *> -> convert(v)
                                is List<*> -> v.map { item -> if (item is Map<*, *>) convert(item) else item }
                                else -> v
                            }
                        }
                    }
                    convert(raw)
                }

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
                            provenance = provenance,
                        )
                    )
                    val transfersDir = java.io.File(context.filesDir, "transfers")
                    val metaFile = java.io.File(transfersDir, "$jobId.meta")
                    TransferMeta.write(
                        metaFile,
                        TransferMeta(
                            url = url,
                            mime = mime,
                            policyKey = policyKey,
                            provenance = provenance,
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
                val job = scheduler.store.getJob(jobId)

                if (job != null && job.state == JobState.DONE) {
                    result.success(
                        mapOf(
                            "exists" to true,
                            "mediaId" to job.mediaId,
                            "title" to job.title,
                            "size" to job.fileSize,
                            "md5" to job.md5,
                            "partSha256" to job.partSha256,
                            "sha256" to (job.partSha256 ?: ""),
                            "provenanceStatus" to job.provenanceStatus,
                            "readbackMatch" to job.readbackMatch,
                        )
                    )
                } else if (!partFile.exists()) {
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
                            "partSha256" to sha256,
                            "path" to partFile.absolutePath,
                        )
                    )
                }
            }
            "computeMediaSha256" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val jobId = args["jobId"] as? String ?: ""
                val mediaId = args["mediaId"] as? String
                channelScope.launch(Dispatchers.IO) {
                    try {
                        val sha256 = if (!mediaId.isNullOrBlank()) {
                            val publisher = scheduler.publisher ?: MediaStorePublisher(context)
                            val md = java.security.MessageDigest.getInstance("SHA-256")
                            val buf = ByteArray(65536)
                            publisher.openSeekableInput(mediaId).use { input ->
                                input.seek(0)
                                while (true) {
                                    val n = input.read(buf, 0, buf.size)
                                    if (n <= 0) break
                                    md.update(buf, 0, n)
                                }
                            }
                            md.digest().joinToString("") { "%02x".format(it) }
                        } else {
                            val transfersDir = java.io.File(context.filesDir, "transfers")
                            val partFile = java.io.File(transfersDir, "$jobId.part")
                            if (!partFile.exists()) {
                                null
                            } else {
                                val md = java.security.MessageDigest.getInstance("SHA-256")
                                val buf = ByteArray(65536)
                                partFile.inputStream().use { stream ->
                                    var read: Int
                                    while (stream.read(buf).also { read = it } > 0) {
                                        md.update(buf, 0, read)
                                    }
                                }
                                md.digest().joinToString("") { "%02x".format(it) }
                            }
                        }
                        mainHandler.post {
                            result.success(sha256 ?: "")
                        }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.error("COMPUTE_FAILED", t.message, null)
                        }
                    }
                }
            }
            "openInGallery" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val mediaId = args["mediaId"] as? String ?: ""
                val mime = args["mime"] as? String ?: "*/*"
                if (mediaId.isBlank()) {
                    result.error("INVALID_ARGUMENT", "mediaId is blank", null)
                } else {
                    try {
                        val uri = if (mediaId.startsWith("content://")) {
                            android.net.Uri.parse(mediaId)
                        } else {
                            val collection = if (mime.startsWith("video/")) {
                                android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                            } else {
                                android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                            }
                            android.net.Uri.withAppendedPath(collection, mediaId)
                        }
                        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mime)
                            addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        context.startActivity(intent)
                        result.success(true)
                    } catch (t: Throwable) {
                        result.error("OPEN_FAILED", t.message, null)
                    }
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
            is TransferEvent.Completed -> event.toMap()
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
