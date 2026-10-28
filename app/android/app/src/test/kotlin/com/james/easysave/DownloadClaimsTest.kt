package com.james.easysave

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch

class DownloadClaimsTest {
    @Test fun deletionCancelsPendingStartsAcrossEnginesWithoutBlockingNewSaves() {
        val registry = DownloadClaims()
        registry.reserve("background", listOf("tiktok:123:1:image"), emptyMap())
        registry.reserve("main", listOf("xhs:123:1:image"), emptyMap())
        assertEquals(listOf("background"), registry.cancelPost("tiktok:123:"))
        assertTrue(registry.isCancelled("background"))
        assertFalse(registry.isCancelled("main"))
        assertTrue(registry.reserve("background", listOf("tiktok:123:1:image"), emptyMap()).isEmpty())
        assertEquals(1, registry.reserve("fresh", listOf("tiktok:123:1:image"), emptyMap()).size)
    }
    @Test fun tenConcurrentEngineRequestsHaveOneWinner() {
        val registry = DownloadClaims()
        val pool = Executors.newFixedThreadPool(10)
        val start = CountDownLatch(1)
        try {
            val results = (1..10).map { id -> pool.submit<Boolean> {
                start.await()
                registry.reserve("engine-$id", listOf("tiktok:123:2:image"), emptyMap()).isNotEmpty()
            } }
            start.countDown()
            assertEquals(1, results.count { it.get() })
        } finally { pool.shutdownNow() }
    }
    @Test fun restartSeedsLiveTasksAndReleaseAllowsNewBatch() {
        val registry = DownloadClaims()
        assertTrue(registry.reserve("new", listOf("image"), mapOf("image" to "old")).isEmpty())
        registry.release("old")
        assertEquals(listOf("image"), registry.reserve("new", listOf("image"), emptyMap()))
    }
    @Test fun onlyOverlappingMediaIsExcluded() {
        val registry = DownloadClaims()
        registry.reserve("main", listOf("image"), emptyMap())
        assertEquals(listOf("video"), registry.reserve("background", listOf("image", "video"), emptyMap()))
        registry.release("background")
        assertTrue(registry.reserve("third", listOf("image"), emptyMap()).isEmpty())
    }
}
