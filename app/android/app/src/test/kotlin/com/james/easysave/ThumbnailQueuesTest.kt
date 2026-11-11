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
    @Test fun committedReadsStayUnder100msWhileDownloadsPrefetchAndValidationAreBlocked() {
        val release = CountDownLatch(1)
        val validating = CountDownLatch(1)
        val waits = Collections.synchronizedList(mutableListOf<Long>())
        val queues = ThumbnailQueues { queue, wait, _, _ -> if (queue == "read") waits.add(wait) }
        val network = Executors.newFixedThreadPool(4)
        val prefetch = Executors.newFixedThreadPool(2)
        val root = Files.createTempDirectory("easysave-build23-contention-").toFile()
        val cache = ThumbnailFiles(root, validateImage = {
            if (it.readBytes().first() == 9.toByte()) { validating.countDown(); release.await(5, TimeUnit.SECONDS) }
            true
        })
        val cachedKey = "a".repeat(64)
        val bytes = ByteArray(512) { 1 }
        cache.write(cachedKey, bytes, System.currentTimeMillis() + 600_000)
        try {
            val warm = CountDownLatch(4)
            repeat(4) { queues.read(cachedKey, { cache.readPath(root.resolve(cachedKey).path) }) { warm.countDown() } }
            assertTrue(warm.await(2, TimeUnit.SECONDS))
            waits.clear()
            queues.write("blocked-validation", { cache.write("b".repeat(64), ByteArray(512) { 9 }, System.currentTimeMillis() + 600_000) }) {}
            assertTrue(validating.await(2, TimeUnit.SECONDS))
            val speculativeRead = CountDownLatch(1)
            queues.prefetchReadInfo("blocked-prefetch-read", {
                speculativeRead.countDown(); release.await(5, TimeUnit.SECONDS); null
            }) {}
            assertTrue(speculativeRead.await(2, TimeUnit.SECONDS))
            repeat(30) { queues.write("scan-$it", { cache.clean() }) {} }
            val downloading = CountDownLatch(6)
            repeat(20) { network.execute { downloading.countDown(); release.await(5, TimeUnit.SECONDS) } }
            repeat(10) { prefetch.execute { downloading.countDown(); release.await(5, TimeUnit.SECONDS) } }
            assertTrue(downloading.await(2, TimeUnit.SECONDS))
            val complete = CountDownLatch(24)
            val errors = Collections.synchronizedList(mutableListOf<Throwable>())
            repeat(24) {
                queues.read(cachedKey, { cache.readPath(root.resolve(cachedKey).path) }) { result ->
                    runCatching { assertArrayEquals(bytes, result.getOrThrow()) }.exceptionOrNull()?.let(errors::add)
                    complete.countDown()
                }
            }
            assertTrue("Read executor blocked behind writers or networking", complete.await(2, TimeUnit.SECONDS))
            assertTrue(errors.toString(), errors.isEmpty())
            assertEquals(24, waits.size)
            assertTrue("read waitMs=$waits", waits.all { it < 100 })
            println("ThumbQueueBenchmark reads=24 maxWaitMs=${waits.maxOrNull()} thresholdMs=100 blocked=download,prefetch,write,scan,validation")
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
