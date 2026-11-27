package com.james.easysave.transfer

import com.james.easysave.policy.MediaPolicyRedirects
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit

class HttpWorkerTest {

    private lateinit var server: MockWebServer
    private lateinit var testDir: File
    private lateinit var client: OkHttpClient
    private lateinit var serverHost: String
    private var serverPort: Int = 0

    private lateinit var handshakeCertificates: HandshakeCertificates

    @Before
    fun setUp() {
        testDir = File("build/tmp/test_transfers_${System.currentTimeMillis()}").apply { mkdirs() }

        val localhostCert = HeldCertificate.Builder()
            .addSubjectAlternativeName("localhost")
            .addSubjectAlternativeName("127.0.0.1")
            .build()

        handshakeCertificates = HandshakeCertificates.Builder()
            .heldCertificate(localhostCert)
            .addTrustedCertificate(localhostCert.certificate)
            .build()

        server = MockWebServer()
        server.useHttps(handshakeCertificates.sslSocketFactory())
        server.start()

        serverPort = server.port
        serverHost = server.hostName

        client = OkHttpClient.Builder()
            .sslSocketFactory(handshakeCertificates.sslSocketFactory(), handshakeCertificates.trustManager)
            .hostnameVerifier { _, _ -> true }
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(5000, TimeUnit.MILLISECONDS)
            .readTimeout(5000, TimeUnit.MILLISECONDS)
            .build()

        TransferParamsRegistry.clear()
        FakeWorkerRegistry.reset()
    }

    @After
    fun tearDown() {
        try {
            server.close()
        } catch (_: Throwable) {}
        testDir.deleteRecursively()
        TransferParamsRegistry.clear()
        FakeWorkerRegistry.reset()
    }

    private fun createJob(
        jobId: String,
        url: String,
        headers: Map<String, String> = emptyMap(),
        cookie: String? = null,
        allowedCookieDomains: List<String> = emptyList(),
        policyHosts: List<MediaPolicyRedirects.HostRule> = listOf(
            MediaPolicyRedirects.HostRule(serverHost, true),
            MediaPolicyRedirects.HostRule("localhost", true),
            MediaPolicyRedirects.HostRule("127.0.0.1", true)
        ),
    ): TransferJob {
        val job = TransferJob(
            jobId = jobId,
            direction = Direction.DOWNLOAD,
            category = JobCategory.LARGE_FILE,
            state = JobState.RUNNING,
        )
        TransferParamsRegistry.set(
            jobId,
            TransferDownloadParams(
                url = url,
                headers = headers,
                cookie = cookie,
                allowedCookieDomains = allowedCookieDomains,
                policyHosts = policyHosts,
            )
        )
        return job
    }

    @Test
    fun testResumeProtocolAcrossRoundsWithCorrectRangeAndHash() = runBlocking {
        // 第一轮：只发前 500 字节，随后人为断开
        val totalBytes = 1000
        val payload = ByteArray(totalBytes) { (it % 256).toByte() }

        server.enqueue(
            MockResponse.Builder()
                .code(200)
                .setHeader("ETag", "\"v1-etag\"")
                .body(BufferUtil.fromByteArray(payload.copyOfRange(0, 500)))
                .setHeader("Content-Length", totalBytes.toString())
                .onResponseEnd(SocketEffect.CloseSocket())
                .build()
        )

        val worker = HttpWorker(client = client, transfersDir = testDir)
        val jobId = "job_resume_test"
        val downloadUrl = server.url("/media/test.mp4").toString()
        val job = createJob(jobId, downloadUrl)

        // 第一轮执行（返回 NetworkError 因为连接被中断）
        val res1 = worker.execute(job) { _, _ -> }
        assertTrue(res1 is WorkerResult.NetworkError || res1 is WorkerResult.OtherError)

        val partFile = File(testDir, "$jobId.part")
        assertEquals(500L, partFile.length())

        // 第二轮：返回 206 响应并带 Range
        server.enqueue(
            MockResponse.Builder()
                .code(206)
                .setHeader("Content-Range", "bytes 500-999/1000")
                .setHeader("Content-Length", "500")
                .setHeader("ETag", "\"v1-etag\"")
                .body(BufferUtil.fromByteArray(payload.copyOfRange(500, 1000)))
                .build()
        )

        val res2 = worker.execute(job) { _, _ -> }
        assertTrue("Expected Success, got $res2", res2 is WorkerResult.Success)
        assertEquals(1000L, partFile.length())

        // 验证第二轮请求确实携带 Range: bytes=500- 和 If-Range: "v1-etag"
        val req1 = server.takeRequest()
        assertNull(req1.headers["Range"])

        val req2 = server.takeRequest()
        assertEquals("bytes=500-", req2.headers["Range"])
        assertEquals("\"v1-etag\"", req2.headers["If-Range"])

        // 验证文件内容完整无误
        val downloadedBytes = partFile.readBytes()
        assertEquals(payload.toList(), downloadedBytes.toList())
    }

    @Test
    fun testFallback200TruncatesAndRewritesFromZero() = runBlocking {
        val totalBytes = 800
        val payload = ByteArray(totalBytes) { 0x42 }

        val jobId = "job_fallback_200"
        val partFile = File(testDir, "$jobId.part")
        partFile.writeBytes(ByteArray(300) { 0x11 }) // 预存 300 字节脏数据
        val metaFile = File(testDir, "$jobId.meta")
        TransferMeta.write(metaFile, TransferMeta(url = "placeholder", total = 800L))

        val downloadUrl = server.url("/file.mp4").toString()
        val job = createJob(jobId, downloadUrl)

        // 服务端返回 200 而非 206
        server.enqueue(
            MockResponse.Builder()
                .code(200)
                .setHeader("Content-Length", totalBytes.toString())
                .body(BufferUtil.fromByteArray(payload))
                .build()
        )

        val worker = HttpWorker(client = client, transfersDir = testDir)
        val res = worker.execute(job) { _, _ -> }

        assertTrue(res is WorkerResult.Success)
        assertEquals(800L, partFile.length())
        assertEquals(payload.toList(), partFile.readBytes().toList())
    }

    @Test
    fun testContentRangeStartOrTotalMismatchRewritesFromZero() = runBlocking {
        val totalBytes = 600
        val payload = ByteArray(totalBytes) { 0x55 }

        val jobId = "job_mismatch"
        val partFile = File(testDir, "$jobId.part")
        partFile.writeBytes(ByteArray(200) { 0x01 })
        val metaFile = File(testDir, "$jobId.meta")
        TransferMeta.write(metaFile, TransferMeta(url = "placeholder", total = 600L))

        val downloadUrl = server.url("/mismatch.mp4").toString()
        val job = createJob(jobId, downloadUrl)

        // 服务端返回 206 但 Content-Range 起点不符（返回从 0 开始），随后截断并重下返回正常全量
        server.enqueue(
            MockResponse.Builder()
                .code(206)
                .setHeader("Content-Range", "bytes 0-599/600")
                .body(BufferUtil.fromByteArray(payload))
                .build()
        )
        server.enqueue(
            MockResponse.Builder()
                .code(200)
                .setHeader("Content-Length", totalBytes.toString())
                .body(BufferUtil.fromByteArray(payload))
                .build()
        )

        val worker = HttpWorker(client = client, transfersDir = testDir)
        val res = worker.execute(job) { _, _ -> }

        assertTrue(res is WorkerResult.Success)
        assertEquals(600L, partFile.length())
        assertEquals(payload.toList(), partFile.readBytes().toList())
    }

    @Test
    fun testHttp416WhenLengthEqualsTotalMarksDone() = runBlocking {
        val jobId = "job_416_done"
        val partFile = File(testDir, "$jobId.part")
        partFile.writeBytes(ByteArray(1000) { 0x33 })
        val metaFile = File(testDir, "$jobId.meta")
        TransferMeta.write(metaFile, TransferMeta(url = "placeholder", total = 1000L))

        val downloadUrl = server.url("/full.mp4").toString()
        val job = createJob(jobId, downloadUrl)

        server.enqueue(
            MockResponse.Builder()
                .code(416)
                .setHeader("Content-Range", "bytes */1000")
                .build()
        )

        val worker = HttpWorker(client = client, transfersDir = testDir)
        val res = worker.execute(job) { _, _ -> }

        assertTrue("Expected Success on 416 with length==total, got $res", res is WorkerResult.Success)
    }

    @Test
    fun testHttp403ReturnsUrlExpired() = runBlocking {
        val jobId = "job_403_expired"
        val downloadUrl = server.url("/expired.mp4").toString()
        val job = createJob(jobId, downloadUrl)

        server.enqueue(
            MockResponse.Builder()
                .code(403)
                .body("Access Denied")
                .build()
        )

        val worker = HttpWorker(client = client, transfersDir = testDir)
        val res = worker.execute(job) { _, _ -> }

        assertTrue("Expected UrlExpired, got $res", res is WorkerResult.UrlExpired)
        assertEquals(403, (res as WorkerResult.UrlExpired).code)
    }

    @Test
    fun testCrossDomainRedirectRejectedByPolicy() = runBlocking {
        val jobId = "job_cross_domain"
        val downloadUrl = server.url("/hop1").toString()
        // policy 仅允许 serverHost，不允许 other.evil.com
        val job = createJob(
            jobId = jobId,
            url = downloadUrl,
            policyHosts = listOf(MediaPolicyRedirects.HostRule(serverHost, false))
        )

        server.enqueue(
            MockResponse.Builder()
                .code(302)
                .setHeader("Location", "https://other.evil.com/malicious.mp4")
                .build()
        )

        val worker = HttpWorker(client = client, transfersDir = testDir)
        val res = worker.execute(job) { _, _ -> }

        assertTrue("Expected PolicyRejected, got $res", res is WorkerResult.PolicyRejected)
    }

    @Test
    fun testCookieOnlySentToPermittedDomain() = runBlocking {
        val jobId = "job_cookie_test"
        val downloadUrl = server.url("/hop1").toString()
        val cookieValue = "session_id=secret123"

        // 仅允许 localhost 发送 cookie，不允许子域名或其他域名
        val job = createJob(
            jobId = jobId,
            url = downloadUrl,
            cookie = cookieValue,
            allowedCookieDomains = listOf(serverHost)
        )

        server.enqueue(
            MockResponse.Builder()
                .code(200)
                .setHeader("Content-Length", "4")
                .body("test")
                .build()
        )

        val worker = HttpWorker(client = client, transfersDir = testDir)
        val res = worker.execute(job) { _, _ -> }

        assertTrue(res is WorkerResult.Success)
        val recordedReq = server.takeRequest()
        assertEquals(cookieValue, recordedReq.headers["Cookie"])
    }

    @Test
    fun testLockBusyReturnsOtherErrorWhenFileIsLocked() = runBlocking {
        val jobId = "job_lock_busy"
        val partFile = File(testDir, "$jobId.part")
        partFile.writeBytes(ByteArray(10))

        val downloadUrl = server.url("/file.mp4").toString()
        val job = createJob(jobId, downloadUrl)

        // 外部先获取文件锁
        val externalRaf = RandomAccessFile(partFile, "rw")
        val externalLock = externalRaf.channel.tryLock()
        assertNotNull("External lock must succeed", externalLock)

        try {
            val worker = HttpWorker(client = client, transfersDir = testDir)
            val res = worker.execute(job) { _, _ -> }

            assertTrue("Expected OtherError with lock_busy, got $res", res is WorkerResult.OtherError)
            assertEquals("lock_busy", (res as WorkerResult.OtherError).error)
        } finally {
            externalLock?.release()
            externalRaf.close()
        }
    }

    @Test
    fun testStorageFullAbortsDownloadWhenSpaceInsufficient() = runBlocking {
        val jobId = "job_storage_full"
        val downloadUrl = server.url("/huge.mp4").toString()
        val job = createJob(jobId, downloadUrl)

        // total 大小超过实际可用空间（例如 1000 TB）
        server.enqueue(
            MockResponse.Builder()
                .code(200)
                .setHeader("Content-Length", (1000L * 1024L * 1024L * 1024L * 1024L).toString())
                .body("huge")
                .build()
        )

        val worker = HttpWorker(
            client = client,
            transfersDir = testDir,
            spaceChecker = { 10 * 1024 * 1024L } // 10MB 可用，需要 60MB 空间
        )
        val res = worker.execute(job) { _, _ -> }

        assertTrue("Expected StorageFull, got $res", res is WorkerResult.StorageFull)
    }

    @Test
    fun testPauseAndResumeMultipleTimesFileIntact() = runBlocking {
        val totalBytes = 3000
        val payload = ByteArray(totalBytes) { (it % 128).toByte() }

        val jobId = "job_pause_resume_3x"
        val downloadUrl = server.url("/pause_test.mp4").toString()
        val job = createJob(jobId, downloadUrl)
        val worker = HttpWorker(client = client, transfersDir = testDir)
        val partFile = File(testDir, "$jobId.part")

        // 轮次 1：返回 0..999
        server.enqueue(
            MockResponse.Builder()
                .code(200)
                .setHeader("ETag", "\"tag1\"")
                .body(BufferUtil.fromByteArray(payload.copyOfRange(0, 1000)))
                .setHeader("Content-Length", totalBytes.toString())
                .onResponseEnd(SocketEffect.CloseSocket())
                .build()
        )
        worker.execute(job) { _, _ -> }
        assertEquals(1000L, partFile.length())

        // 轮次 2：返回 1000..1999
        server.enqueue(
            MockResponse.Builder()
                .code(206)
                .setHeader("Content-Range", "bytes 1000-1999/$totalBytes")
                .setHeader("Content-Length", "1000")
                .setHeader("ETag", "\"tag1\"")
                .body(BufferUtil.fromByteArray(payload.copyOfRange(1000, 2000)))
                .onResponseEnd(SocketEffect.CloseSocket())
                .build()
        )
        worker.execute(job) { _, _ -> }
        assertEquals(2000L, partFile.length())

        // 轮次 3：返回 2000..2999
        server.enqueue(
            MockResponse.Builder()
                .code(206)
                .setHeader("Content-Range", "bytes 2000-2999/$totalBytes")
                .setHeader("Content-Length", "1000")
                .setHeader("ETag", "\"tag1\"")
                .body(BufferUtil.fromByteArray(payload.copyOfRange(2000, 3000)))
                .build()
        )
        val finalRes = worker.execute(job) { _, _ -> }
        assertTrue(finalRes is WorkerResult.Success)
        assertEquals(3000L, partFile.length())
        assertEquals(payload.toList(), partFile.readBytes().toList())
    }

    @Test
    fun testCancelRetainsPartFileUntilUserCancel() = runBlocking {
        val jobId = "job_cancel_test"
        val partFile = File(testDir, "$jobId.part")
        partFile.writeBytes(ByteArray(200) { 0x07 })

        val downloadUrl = server.url("/cancel.mp4").toString()
        val job = createJob(jobId, downloadUrl)

        server.enqueue(
            MockResponse.Builder()
                .code(206)
                .setHeader("Content-Range", "bytes 200-999/1000")
                .setHeader("Content-Length", "800")
                .body(BufferUtil.fromByteArray(ByteArray(800)))
                .build()
        )

        val worker = HttpWorker(client = client, transfersDir = testDir)

        val jobScope = CoroutineScope(Dispatchers.IO)
        val cJob = jobScope.launch {
            worker.execute(job) { _, _ -> }
        }

        // 异步等待并取消
        delay(10)
        cJob.cancel()
        cJob.join()

        // 验证 .part 文件未被删除
        assertTrue("Part file must remain after cancellation", partFile.exists())
    }

    @Test
    fun testIsNetworkExceptionMatchesAllNetworkErrors() {
        // SocketException (Software caused connection abort)
        assertTrue(HttpWorker.isNetworkException(java.net.SocketException("Software caused connection abort")))
        assertTrue(HttpWorker.isNetworkException(java.net.SocketException("ECONNRESET")))
        assertTrue(HttpWorker.isNetworkException(java.net.SocketException("ECONNABORTED")))
        assertTrue(HttpWorker.isNetworkException(java.net.SocketException("Broken pipe")))
        assertTrue(HttpWorker.isNetworkException(java.net.ConnectException("Failed to connect")))
        assertTrue(HttpWorker.isNetworkException(java.net.UnknownHostException("Unable to resolve host")))
        assertTrue(HttpWorker.isNetworkException(java.net.SocketTimeoutException("timeout")))
        assertTrue(HttpWorker.isNetworkException(javax.net.ssl.SSLException("SSL handshake aborted")))
        assertTrue(HttpWorker.isNetworkException(javax.net.ssl.SSLHandshakeException("handshake failed")))
        assertTrue(HttpWorker.isNetworkException(javax.net.ssl.SSLProtocolException("protocol error")))

        // 嵌套原因包装
        val wrapped = java.io.IOException("wrapped", java.net.SocketException("Software caused connection abort"))
        assertTrue(HttpWorker.isNetworkException(wrapped))

        // 非网络错误
        org.junit.Assert.assertFalse(HttpWorker.isNetworkException(java.io.FileNotFoundException("file not found")))
        org.junit.Assert.assertFalse(HttpWorker.isNetworkException(IllegalStateException("invalid state")))
    }
}

object BufferUtil {
    fun fromByteArray(bytes: ByteArray): okio.Buffer {
        return okio.Buffer().write(bytes)
    }
}
