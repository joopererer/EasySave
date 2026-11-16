package com.james.easysave

import java.nio.file.Files
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class ThumbnailQueuesTest {
    @Test fun visibilityPausesOtherPrefetchAcrossEnginesAndPromotesMatchingKey() {
        val visibility = ThumbnailVisibility()
        visibility.begin("visible")
        visibility.begin("visible")
        assertFalse(visibility.idle("prefetch"))
        assertTrue(visibility.idle("visible"))
        assertTrue(visibility.contains("visible"))
        visibility.end("visible")
        assertFalse(visibility.idle(null))
        visibility.end("visible")
        assertTrue(visibility.idle(null))
        val app = Any(); val overlay = Any()
        visibility.begin("visible", app); visibility.begin("visible", overlay)
        visibility.detach(app)
        assertFalse(visibility.idle(null))
        visibility.detach(overlay)
        assertTrue(visibility.idle(null))
    }
    // What this test wants to guarantee: the reader executor is independent, so
    // committed thumbnail reads are served while downloads, prefetch, writes,
    // scans and image validation are still blocked. It used to assert
    // `waitMs < 100` for every read, which measured the test machine's load as
    // much as the queue design (it fails on a busy CI box while nothing is
    // wrong). The order below is the real invariant: every read finishes while
    // the other queues are still parked on their latch, so a read cannot have
    // been waiting behind them. The waits are still collected and printed as
    // information, never as a threshold.
    @Test fun readsCompleteWhileDownloadPrefetchWriteScanAndValidationStayBlocked() {
        val release = CountDownLatch(1)
        val validating = CountDownLatch(1)
        val waits = Collections.synchronizedList(mutableListOf<Long>())
        val queues = ThumbnailQueues { queue, wait, _, _ -> if (queue == "read") waits.add(wait) }
        val network = Executors.newFixedThreadPool(4)
        val prefetch = Executors.newFixedThreadPool(2)
        val root = Files.createTempDirectory("easysave-build23-contention-").toFile()
        val cache = ThumbnailFiles(root, validateImage = {
            if (it.readBytes().first() == 9.toByte()) { validating.countDown(); release.await(10, TimeUnit.SECONDS) }
            true
        })
        val cachedKey = "a".repeat(64)
        val bytes = ByteArray(512) { 1 }
        cache.write(cachedKey, bytes, System.currentTimeMillis() + 600_000)
        try {
            val warm = CountDownLatch(4)
            repeat(4) { queues.read(cachedKey, { cache.readPath(root.resolve(cachedKey).path) }) { warm.countDown() } }
            assertTrue("the warm-up reads must finish", warm.await(10, TimeUnit.SECONDS))
            waits.clear()
            // Every other queue is now blocked on `release`, which only the
            // finally block opens.
            queues.write("blocked-validation", { cache.write("b".repeat(64), ByteArray(512) { 9 }, System.currentTimeMillis() + 600_000) }) {}
            assertTrue("the validating write must be blocked", validating.await(10, TimeUnit.SECONDS))
            val speculativeRead = CountDownLatch(1)
            queues.prefetchReadInfo("blocked-prefetch-read", {
                speculativeRead.countDown(); release.await(10, TimeUnit.SECONDS); null
            }) {}
            assertTrue("the prefetch read must be blocked", speculativeRead.await(10, TimeUnit.SECONDS))
            repeat(30) { queues.write("scan-$it", { cache.clean() }) {} }
            val downloading = CountDownLatch(6)
            repeat(20) { network.execute { downloading.countDown(); release.await(10, TimeUnit.SECONDS) } }
            repeat(10) { prefetch.execute { downloading.countDown(); release.await(10, TimeUnit.SECONDS) } }
            assertTrue("the downloading work must be blocked", downloading.await(10, TimeUnit.SECONDS))

            val complete = CountDownLatch(24)
            val errors = Collections.synchronizedList(mutableListOf<Throwable>())
            repeat(24) {
                queues.read(cachedKey, { cache.readPath(root.resolve(cachedKey).path) }) { result ->
                    runCatching { assertArrayEquals(bytes, result.getOrThrow()) }.exceptionOrNull()?.let(errors::add)
                    complete.countDown()
                }
            }
            // 10s is a livelock guard, not a latency budget: the blocked work
            // is still parked, so a completed read proves it never queued
            // behind it.
            assertTrue("read executor blocked behind writers or networking", complete.await(10, TimeUnit.SECONDS))
            assertEquals("the blocked queues must still be blocked", 1, release.count)
            assertTrue(errors.toString(), errors.isEmpty())
            assertEquals("every read went through the read queue", 24, waits.size)
            println("ThumbQueueOrder reads=24 maxWaitMs=${waits.maxOrNull()} blocked=download,prefetch,write,scan,validation")
        } finally { release.countDown(); queues.close(); network.shutdownNow(); prefetch.shutdownNow() }
    }

    @Test fun secondOpenOfEntirePostUsesStableMemoryKeysWithoutAnyReadOrDecode() {
        val cache = ThumbnailMemory<ByteArray>(1024 * 1024, { it.size.toLong() }) { 1000L }
        var reads = 0
        var decodes = 0
        fun open(): Int {
            var hits = 0
            repeat(20) { index ->
                val key = "instagram:synthetic:$index:thumb:320"
                if (cache.get(key) != null) hits++ else {
                    reads++; decodes++
                    cache.put(key, ByteArray(1024), 2000L)
                }
            }
            return hits
        }
        assertEquals(0, open())
        reads = 0; decodes = 0
        assertEquals(20, open())
        assertEquals(0, reads); assertEquals(0, decodes)
        println("ThumbMemoryBenchmark secondOpenHits=20 diskReads=0 decodes=0")
    }

    @Test fun bitmapMemoryIsBoundedUsesLruAndExpires() {
        var now = 1L
        val cache = ThumbnailMemory<ByteArray>(6, { it.size.toLong() }) { now }
        cache.put("a", ByteArray(3), 100)
        cache.put("b", ByteArray(3), 100)
        assertNotNull(cache.get("a"))
        cache.put("c", ByteArray(3), 100)
        assertNull(cache.get("b")); assertNotNull(cache.get("a"))
        cache.put("oversize", ByteArray(7), 100)
        assertNull(cache.get("oversize"))
        now = 101
        assertNull(cache.get("a")); assertNull(cache.get("c"))
    }
}
