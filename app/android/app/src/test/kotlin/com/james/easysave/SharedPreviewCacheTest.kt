package com.james.easysave

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class SharedPreviewCacheTest {
    @Test fun centralLookupReportsTenMinuteExpiry() {
        var now = 1000L
        val handoff = ParsedHandoff { now }
        handoff.put(mapOf("canonical" to "xhs:123", "keys" to listOf("xhs:123")))
        now += 540_000
        assertEquals("hit", handoff.lookup("xhs:123")["status"])
        now += 60_001
        assertEquals("expired", handoff.lookup("xhs:123")["status"])
        assertEquals("miss", handoff.lookup("xhs:123")["status"])
    }
    @Test fun everyStoreReplacesTheCanonicalPostAndRetainsKnownAliases() {
        val handoff = ParsedHandoff { 1L }
        handoff.put(mapOf("canonical" to "xhs:123", "keys" to listOf("xhs:123", "short"), "revision" to 1))
        handoff.put(mapOf("canonical" to "xhs:123", "keys" to listOf("xhs:123"), "revision" to 2))
        val found = handoff.lookup("short")["value"] as Map<*, *>
        assertEquals(2, found["revision"])
    }
    @Test fun parsedHandoffExpiresAndRecognizesCanonicalAliases() {
        var now = 1000L
        val handoff = ParsedHandoff { now }
        handoff.put(mapOf("keys" to listOf("xhs:123", "shortAlias"), "post" to "synthetic"))
        assertNotNull(handoff.get("xhs:123"))
        assertNotNull(handoff.get("shortAlias"))
        now += 540_000
        assertNotNull(handoff.get("xhs:123"))
        now += 60_001
        assertNull(handoff.get("xhs:123"))
    }
    @Test fun handoffHasABoundedNumberOfPosts() {
        val handoff = ParsedHandoff { 1L }
        repeat(9) { handoff.put(mapOf("keys" to listOf("post:$it"))) }
        assertNull(handoff.get("post:0"))
        assertNotNull(handoff.get("post:8"))
    }
    @Test fun thumbnailsEvictExpireAndRejectPathsOutsideTheCache() {
        val root = Files.createTempDirectory("easysave-synthetic-cache-").toFile()
        var now = 1000L
        val cache = ThumbnailFiles(root, 10) { now }
        val first = "a".repeat(64)
        val second = "b".repeat(64)
        assertNotNull(cache.write(first, byteArrayOf(1,2,3,4,5,6), 2000L))
        assertNotNull(cache.write(second, byteArrayOf(7,8,9,0,1,2), 3000L))
        assertNull(cache.read(first))
        assertTrue(root.listFiles()!!.sumOf { it.length() } <= 10)
        assertArrayEquals(byteArrayOf(7,8,9,0,1,2), cache.readPath(cache.read(second)!!.path))
        assertNull(cache.readPath(root.parentFile.resolve("unrelated").path))
        assertNull(cache.read("../unrelated"))
        now = 3001L
        assertNull(cache.read(second))
    }
}
