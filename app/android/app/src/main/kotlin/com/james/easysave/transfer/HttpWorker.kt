package com.james.easysave.transfer

import android.content.Context
import com.james.easysave.policy.MediaPolicyRedirects
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.isActive
import okhttp3.Call
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.URI
import java.nio.channels.FileLock
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

/**
 * 真实下载 Worker（OkHttp 5.5.1 + 续传协议 + 请求策略校验）。
 *
 * 核心规范：
 * 1. OkHttpClient: followRedirects(false), followSslRedirects(false), CookieJar.NO_COOKIES, connectTimeout=8000ms, readTimeout=12000ms;
 * 2. 手动处理跳转（最多 5 跳）。每一跳发包前用 policy 校验目标域名和请求头；不在白名单直接终止 (policy_rejected -> failed);
 * 3. Cookie 只来自 enqueue 时内存传入的参数，只发给 policy 允许的域名；不写入 Store、.meta 和日志；
 * 4. 文件：filesDir/transfers/<jobId>.part 和 <jobId>.meta。写入前用 FileChannel.tryLock 锁 .part；拿不到锁记 lock_busy 并按其他错误退避；
 * 5. 续传协议：起点 = .part 实际长度；206 校验 Content-Range 起点与总大小再追加写；200/起点不符/总大小不符截断到 0 重写，记 restart_detected；
 *    416 且长度=total 进 finishing；403/410 进 interrupted，原因 url_expired，并通过 EventChannel 发出 reresolve_required 事件；
 * 6. 空间：写入前检查剩余空间 >= 剩余字节 + 50MB，不够进 storage_full；写入遇 ENOSPC 也进 storage_full，.part 保留；
 * 7. 暂停/取消/onTimeout：call.cancel() 停止写入，不删 .part（仅用户取消才删）；
 * 8. 进度：每 256KB 或 1 秒上报一次；
 * 9. 收尾：校验长度等于 total（已知时）-> done，文件保留在 transfers/。
 */
class HttpWorker(
    private val context: Context? = null,
    private val client: OkHttpClient = defaultClient(),
    transfersDir: File? = null,
    private val spaceChecker: (File) -> Long = { it.usableSpace },
) : TransferWorker {

    val targetDir: File = transfersDir
        ?: File(context?.filesDir ?: File("build/transfers"), "transfers")

    companion object {
        const val CONNECT_TIMEOUT_MS = 8000L
        const val READ_TIMEOUT_MS = 12000L
        const val MAX_REDIRECT_HOPS = 5
        const val BUFFER_SIZE = 8192
        const val PROGRESS_REPORT_BYTES = 256 * 1024L
        const val PROGRESS_REPORT_INTERVAL_MS = 1000L
        const val EXTRA_STORAGE_MARGIN_BYTES = 50 * 1024 * 1024L

        fun isNetworkException(t: Throwable): Boolean {
            var curr: Throwable? = t
            while (curr != null) {
                if (curr is java.net.SocketException ||
                    curr is java.net.ConnectException ||
                    curr is java.net.UnknownHostException ||
                    curr is java.net.SocketTimeoutException ||
                    curr is javax.net.ssl.SSLException) {
                    return true
                }
                val msg = curr.message ?: ""
                if (msg.contains("ECONNABORTED", ignoreCase = true) ||
                    msg.contains("ECONNRESET", ignoreCase = true) ||
                    msg.contains("connection abort", ignoreCase = true) ||
                    msg.contains("Software caused connection abort", ignoreCase = true) ||
                    msg.contains("Connection reset", ignoreCase = true) ||
                    msg.contains("Broken pipe", ignoreCase = true)) {
                    return true
                }
                curr = curr.cause
            }
            return false
        }

        fun defaultClient(): OkHttpClient {
            return OkHttpClient.Builder()
                .followRedirects(false)
                .followSslRedirects(false)
                .cookieJar(CookieJar.NO_COOKIES)
                .connectTimeout(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                .readTimeout(READ_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                .build()
        }

        fun parseContentRange(header: String?): Pair<Long, Long>? {
            if (header == null) return null
            val match = Regex("""bytes\s+(\d+)-(\d+)/(\d+|\*)""").find(header.trim()) ?: return null
            val start = match.groupValues[1].toLongOrNull() ?: return null
            val total = if (match.groupValues[3] == "*") -1L else match.groupValues[3].toLongOrNull() ?: -1L
            return Pair(start, total)
        }
    }

    @Volatile
    private var activeCall: Call? = null

    override suspend fun execute(
        job: TransferJob,
        onProgress: suspend (bytesRead: Long, totalBytes: Long) -> Unit,
    ): WorkerResult {
        if (!targetDir.exists()) {
            targetDir.mkdirs()
        }

        val partFile = File(targetDir, "${job.jobId}.part")
        val metaFile = File(targetDir, "${job.jobId}.meta")

        // 1. 获取任务参数（优先从内存获取，若重启恢复则从 .meta 恢复）
        val memoryParams = TransferParamsRegistry.get(job.jobId)
        val storedMeta = TransferMeta.read(metaFile)

        val targetUrl = memoryParams?.url ?: storedMeta?.url
        if (targetUrl.isNullOrBlank()) {
            TransferLog.e("job=${TransferLog.shortId(job.jobId)} missing url in params and meta")
            return WorkerResult.OtherError("missing_url")
        }

        val headers = memoryParams?.headers ?: emptyMap()
        val cookie = memoryParams?.cookie
        val allowedCookieDomains = memoryParams?.allowedCookieDomains ?: emptyList()
        val policyHosts = memoryParams?.policyHosts ?: emptyList()
        val mime = memoryParams?.mime ?: storedMeta?.mime
        val policyKey = memoryParams?.policyKey ?: storedMeta?.policyKey

        // 2. 文件加锁（tryLock）
        var raf: RandomAccessFile? = null
        var fileLock: FileLock? = null
        try {
            raf = RandomAccessFile(partFile, "rw")
            val channel = raf.channel
            fileLock = try {
                channel.tryLock()
            } catch (t: Throwable) {
                null
            }

            if (fileLock == null) {
                TransferLog.w("job=${TransferLog.shortId(job.jobId)} lock_busy")
                return WorkerResult.OtherError("lock_busy")
            }

            // 3. 执行下载流程（支持起点判断与续传）
            return executeDownload(
                job = job,
                partFile = partFile,
                metaFile = metaFile,
                raf = raf,
                targetUrl = targetUrl,
                headers = headers,
                cookie = cookie,
                allowedCookieDomains = allowedCookieDomains,
                policyHosts = policyHosts,
                storedMeta = storedMeta,
                mime = mime,
                policyKey = policyKey,
                onProgress = onProgress,
            )
        } catch (ce: CancellationException) {
            activeCall?.cancel()
            val stoppedAt = partFile.length()
            TransferLog.i("job=${TransferLog.shortId(job.jobId)} stopped_at=$stoppedAt")
            throw ce
        } catch (t: Throwable) {
            val msg = t.message ?: "unknown"
            if (activeCall?.isCanceled() == true) {
                val stoppedAt = partFile.length()
                TransferLog.i("job=${TransferLog.shortId(job.jobId)} stopped_at=$stoppedAt")
                throw CancellationException("stopped_at=$stoppedAt")
            }
            if (isNetworkException(t)) {
                TransferLog.w("job=${TransferLog.shortId(job.jobId)} network error: $msg")
                return WorkerResult.NetworkError(msg)
            }
            if (msg.contains("ENOSPC", ignoreCase = true) || msg.contains("No space left", ignoreCase = true)) {
                TransferLog.w("job=${TransferLog.shortId(job.jobId)} storage_full: $msg")
                return WorkerResult.StorageFull("storage_full")
            }
            TransferLog.e("job=${TransferLog.shortId(job.jobId)} execute exception: $msg", t)
            return WorkerResult.OtherError(msg)
        } finally {
            try {
                fileLock?.release()
            } catch (_: Throwable) {}
            try {
                raf?.close()
            } catch (_: Throwable) {}
            activeCall = null
        }
    }

    private suspend fun executeDownload(
        job: TransferJob,
        partFile: File,
        metaFile: File,
        raf: RandomAccessFile,
        targetUrl: String,
        headers: Map<String, String>,
        cookie: String?,
        allowedCookieDomains: List<String>,
        policyHosts: List<MediaPolicyRedirects.HostRule>,
        storedMeta: TransferMeta?,
        mime: String?,
        policyKey: String?,
        onProgress: suspend (bytesRead: Long, totalBytes: Long) -> Unit,
    ): WorkerResult {
        var startOffset = partFile.length()
        var currentMeta = storedMeta ?: TransferMeta(url = targetUrl, total = -1L, mime = mime, policyKey = policyKey)
        var total = currentMeta.total
        var etag = currentMeta.etag
        var lastModified = currentMeta.lastModified

        var currentUrl = targetUrl
        var currentHop = 0
        var response: Response? = null

        // 重定向与网络请求循环（最多 5 跳）
        while (true) {
            val uri = runCatching { URI(currentUrl) }.getOrNull()
            val host = uri?.host?.lowercase(Locale.ROOT) ?: ""

            // a. Policy 校验 URL 与 Host
            if (policyHosts.isNotEmpty()) {
                val urlRejection = MediaPolicyRedirects.reject(currentUrl, policyHosts)
                if (urlRejection != null) {
                    TransferLog.w("job=${TransferLog.shortId(job.jobId)} policy_rejected code=${urlRejection.code} host=$host")
                    return WorkerResult.PolicyRejected("policy_rejected")
                }
            } else {
                if (uri == null || uri.scheme?.lowercase(Locale.ROOT) != "https" || host.isEmpty() ||
                    uri.rawAuthority?.contains('@') == true || uri.rawUserInfo != null
                ) {
                    TransferLog.w("job=${TransferLog.shortId(job.jobId)} policy_rejected invalid_uri host=$host")
                    return WorkerResult.PolicyRejected("policy_rejected")
                }
            }

            // b. 构建请求头并校验
            val requestHeaders = LinkedHashMap<String, String>()
            for ((k, v) in headers) {
                requestHeaders[k] = v
            }
            if (startOffset > 0) {
                requestHeaders["Range"] = "bytes=$startOffset-"
                if (!etag.isNullOrBlank()) {
                    requestHeaders["If-Range"] = etag
                } else if (!lastModified.isNullOrBlank()) {
                    requestHeaders["If-Range"] = lastModified
                }
            }

            val headerRejection = MediaPolicyRedirects.rejectHeaders(requestHeaders, host)
            if (headerRejection != null) {
                TransferLog.w("job=${TransferLog.shortId(job.jobId)} policy_rejected code=${headerRejection.code} host=$host")
                return WorkerResult.PolicyRejected("policy_rejected")
            }

            // c. Cookie 判定：仅当目标域名符合 allowedCookieDomains 时才附加 Cookie
            val attachCookie = if (!cookie.isNullOrBlank()) {
                allowedCookieDomains.any { d -> host == d || host.endsWith(".$d") }
            } else {
                false
            }

            val reqBuilder = Request.Builder().url(currentUrl)
            for ((k, v) in requestHeaders) {
                reqBuilder.header(k, v)
            }
            if (attachCookie) {
                reqBuilder.header("Cookie", cookie!!)
            }

            val req = reqBuilder.build()
            val call = client.newCall(req)
            activeCall = call

            val resp: Response
            try {
                resp = call.execute()
            } catch (e: IOException) {
                if (call.isCanceled() || !coroutineContext.isActive) {
                    val stoppedAt = partFile.length()
                    throw CancellationException("stopped_at=$stoppedAt")
                }
                TransferLog.w("job=${TransferLog.shortId(job.jobId)} network error: ${e.message}")
                return WorkerResult.NetworkError(e.message ?: "network_error")
            }

            // d. 处理重定向（3xx）
            if (resp.isRedirect) {
                resp.close()
                if (currentHop >= MAX_REDIRECT_HOPS) {
                    TransferLog.w("job=${TransferLog.shortId(job.jobId)} policy_rejected redirect_limit_exceeded")
                    return WorkerResult.PolicyRejected("policy_rejected")
                }
                val location = resp.header("Location")
                if (location.isNullOrBlank()) {
                    TransferLog.w("job=${TransferLog.shortId(job.jobId)} policy_rejected missing_location")
                    return WorkerResult.PolicyRejected("policy_rejected")
                }
                currentUrl = try {
                    uri!!.resolve(location).toString()
                } catch (t: Throwable) {
                    TransferLog.w("job=${TransferLog.shortId(job.jobId)} policy_rejected invalid_location: $location")
                    return WorkerResult.PolicyRejected("policy_rejected")
                }
                currentHop++
                continue
            }

            response = resp
            break
        }

        val finalResp = response ?: return WorkerResult.OtherError("no_response")

        // 4. 处理 HTTP 状态码
        val statusCode = finalResp.code

        // 403 / 410 -> url_expired -> interrupted
        if (statusCode == 403 || statusCode == 410) {
            finalResp.close()
            TransferLog.w("job=${TransferLog.shortId(job.jobId)} url_expired status=$statusCode")
            return WorkerResult.UrlExpired(statusCode, "url_expired")
        }

        // 416 Range Not Satisfiable
        if (statusCode == 416) {
            finalResp.close()
            if (total > 0 && startOffset == total) {
                TransferLog.i("job=${TransferLog.shortId(job.jobId)} 416 with length==total -> done")
                onProgress(total, total)
                return WorkerResult.Success("download_complete")
            } else {
                TransferLog.w("job=${TransferLog.shortId(job.jobId)} restart_detected reason=416_mismatch start=$startOffset total=$total")
                raf.channel.truncate(0)
                raf.seek(0)
                // 截断后重新从 0 发起
                return executeDownload(
                    job = job,
                    partFile = partFile,
                    metaFile = metaFile,
                    raf = raf,
                    targetUrl = currentUrl,
                    headers = headers,
                    cookie = cookie,
                    allowedCookieDomains = allowedCookieDomains,
                    policyHosts = policyHosts,
                    storedMeta = currentMeta.copy(total = -1L),
                    mime = mime,
                    policyKey = policyKey,
                    onProgress = onProgress,
                )
            }
        }

        var isAppend = false

        if (statusCode == 206) {
            // 206 Partial Content
            val contentRange = finalResp.header("Content-Range")
            val parsedRange = parseContentRange(contentRange)
            val rangeStart = parsedRange?.first ?: -1L
            val rangeTotal = parsedRange?.second ?: -1L

            val startMismatch = rangeStart != startOffset
            val totalMismatch = total > 0 && rangeTotal > 0 && rangeTotal != total

            if (startMismatch || totalMismatch) {
                val reason = if (startMismatch) {
                    "start_mismatch: got $rangeStart expected $startOffset"
                } else {
                    "total_mismatch: got $rangeTotal expected $total"
                }
                TransferLog.i("job=${TransferLog.shortId(job.jobId)} restart_detected reason=$reason")
                finalResp.close()
                raf.channel.truncate(0)
                raf.seek(0)
                return executeDownload(
                    job = job,
                    partFile = partFile,
                    metaFile = metaFile,
                    raf = raf,
                    targetUrl = currentUrl,
                    headers = headers,
                    cookie = cookie,
                    allowedCookieDomains = allowedCookieDomains,
                    policyHosts = policyHosts,
                    storedMeta = currentMeta.copy(total = -1L),
                    mime = mime,
                    policyKey = policyKey,
                    onProgress = onProgress,
                )
            }

            if (total <= 0 && rangeTotal > 0) {
                total = rangeTotal
            }
            etag = finalResp.header("ETag") ?: etag
            lastModified = finalResp.header("Last-Modified") ?: lastModified
            currentMeta = currentMeta.copy(
                url = currentUrl,
                total = total,
                etag = etag,
                lastModified = lastModified,
            )
            TransferMeta.write(metaFile, currentMeta)

            raf.seek(startOffset)
            isAppend = true
        } else if (statusCode in 200..299) {
            // 200 OK (或其它 2xx)
            if (startOffset > 0) {
                TransferLog.i("job=${TransferLog.shortId(job.jobId)} restart_detected reason=server_returned_200_not_206")
                raf.channel.truncate(0)
                raf.seek(0)
                startOffset = 0L
            }
            val contentLength = finalResp.header("Content-Length")?.toLongOrNull() ?: -1L
            total = contentLength
            etag = finalResp.header("ETag")
            lastModified = finalResp.header("Last-Modified")
            currentMeta = currentMeta.copy(
                url = currentUrl,
                total = total,
                etag = etag,
                lastModified = lastModified,
            )
            TransferMeta.write(metaFile, currentMeta)
            raf.seek(0)
        } else if (statusCode in 500..599 || statusCode == 429) {
            finalResp.close()
            return WorkerResult.NetworkError("http_$statusCode")
        } else {
            finalResp.close()
            return WorkerResult.OtherError("http_$statusCode")
        }

        // 5. 存储空间检查：检查剩余空间 >= 剩余字节 + 50MB
        val usableSpace = spaceChecker(targetDir)
        val remainingBytes = if (total > 0 && total > startOffset) (total - startOffset) else 0L
        val requiredSpace = remainingBytes + EXTRA_STORAGE_MARGIN_BYTES
        if (usableSpace < requiredSpace) {
            TransferLog.w("job=${TransferLog.shortId(job.jobId)} storage_full: usable=$usableSpace required=$requiredSpace")
            finalResp.close()
            return WorkerResult.StorageFull("storage_full")
        }

        // 6. 流式写入 .part 并定期上报进度（每 256KB 或 1 秒）
        val body = finalResp.body ?: run {
            finalResp.close()
            return WorkerResult.OtherError("empty_body")
        }

        val inputStream = body.byteStream()
        val buffer = ByteArray(BUFFER_SIZE)
        var bytesWrittenSinceReport = 0L
        var lastReportTime = System.currentTimeMillis()
        var currentBytes = startOffset

        try {
            while (true) {
                if (!coroutineContext.isActive) {
                    activeCall?.cancel()
                    break
                }
                val read: Int
                try {
                    read = inputStream.read(buffer)
                } catch (ioe: IOException) {
                    if (activeCall?.isCanceled() == true || !coroutineContext.isActive) {
                        throw CancellationException("stopped_at=$currentBytes")
                    }
                    if (isNetworkException(ioe)) {
                        TransferLog.w("job=${TransferLog.shortId(job.jobId)} network error: ${ioe.message}")
                        return WorkerResult.NetworkError(ioe.message ?: "network_error")
                    }
                    throw ioe
                }
                if (read == -1) break

                try {
                    raf.write(buffer, 0, read)
                } catch (ioe: IOException) {
                    val msg = ioe.message ?: ""
                    if (msg.contains("ENOSPC", ignoreCase = true) || msg.contains("No space left", ignoreCase = true)) {
                        TransferLog.w("job=${TransferLog.shortId(job.jobId)} storage_full on write: $msg")
                        return WorkerResult.StorageFull("storage_full")
                    }
                    throw ioe
                }

                currentBytes += read
                bytesWrittenSinceReport += read
                val now = System.currentTimeMillis()
                if (bytesWrittenSinceReport >= PROGRESS_REPORT_BYTES || now - lastReportTime >= PROGRESS_REPORT_INTERVAL_MS) {
                    onProgress(currentBytes, total)
                    bytesWrittenSinceReport = 0L
                    lastReportTime = now
                }
            }
        } finally {
            try {
                inputStream.close()
            } catch (_: Throwable) {}
            try {
                body.close()
            } catch (_: Throwable) {}
            finalResp.close()
        }

        // 7. 收尾：比对文件大小
        val finalLength = partFile.length()
        onProgress(finalLength, if (total > 0) total else finalLength)

        if (!coroutineContext.isActive || activeCall?.isCanceled() == true) {
            throw CancellationException("stopped_at=$finalLength")
        }

        if (total > 0 && finalLength != total) {
            TransferLog.w("job=${TransferLog.shortId(job.jobId)} length_mismatch: got $finalLength expected $total")
            return WorkerResult.OtherError("length_mismatch: got $finalLength expected $total")
        }

        TransferLog.i("job=${TransferLog.shortId(job.jobId)} download completed successfully (size=$finalLength)")
        return WorkerResult.Success("download_complete")
    }
}

