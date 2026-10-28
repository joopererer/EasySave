package com.james.easysave

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch

class DownloadClaimsTest {
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
