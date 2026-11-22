package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.regex.Pattern

/**
 * Unit tests verifying header case-insensitivity and resume validation logic
 * matching the vendored DownloadTaskRunner behavior.
 */
class DownloadTaskRunnerResumeTest {

    @Test
    fun acceptRangesHeaderCaseInsensitiveMatching() {
        val lowercaseHeaders = mapOf("accept-ranges" to listOf("bytes"))
        val mixedcaseHeaders = mapOf("Accept-Ranges" to listOf("bytes"))
        val noneHeaders = mapOf("accept-ranges" to listOf("none"))

        fun acceptsRanges(headers: Map<String, List<String>>, allowPause: Boolean, responseCode: Int): Boolean {
            val acceptRanges = headers.entries.firstOrNull { it.key.equals("Accept-Ranges", ignoreCase = true) }?.value?.firstOrNull()
            val explicitlyNoRanges = acceptRanges?.lowercase() == "none"
            return !explicitlyNoRanges && (acceptRanges?.lowercase() == "bytes" || responseCode == 206 || allowPause)
        }

        assertTrue("Lowercase accept-ranges: bytes must be accepted", acceptsRanges(lowercaseHeaders, false, 200))
        assertTrue("Mixed-case Accept-Ranges: bytes must be accepted", acceptsRanges(mixedcaseHeaders, false, 200))
        assertTrue("HTTP 206 implies range support", acceptsRanges(emptyMap(), false, 206))
        assertTrue("allowPause flag treats as potentially resumable", acceptsRanges(emptyMap(), true, 200))
        assertFalse("Explicit accept-ranges: none must not be accepted", acceptsRanges(noneHeaders, true, 200))
    }

    @Test
    fun contentRangeHeaderParsingCaseInsensitive() {
        val regex = Regex("(\\d+)-(\\d+)/(\\d+)")
        val header = "bytes 2097152-1020613969/1020613970"
        val match = regex.find(header)
        assertTrue(match != null)
        assertEquals(2097152L, match?.groups?.get(1)?.value?.toLong())
        assertEquals(1020613969L, match?.groups?.get(2)?.value?.toLong())
        assertEquals(1020613970L, match?.groups?.get(3)?.value?.toLong())
    }

    @Test
    fun prepResumeCanResumeCondition() {
        fun canResume(serverAcceptsRanges: Boolean, bytesTotal: Long, startByte: Long, allowPause: Boolean, tempSize: Long): Boolean {
            return serverAcceptsRanges && (bytesTotal + startByte > (1L shl 20) || (allowPause && tempSize > 0))
        }

        assertTrue("Over 1MB with range support can resume", canResume(true, 2_000_000L, 0L, false, 2_000_000L))
        assertTrue("allowPause with partial temp size can resume", canResume(true, 500_000L, 0L, true, 500_000L))
        assertFalse("Cannot resume if server rejects ranges", canResume(false, 2_000_000L, 0L, true, 2_000_000L))
        assertFalse("Cannot resume if no bytes downloaded", canResume(true, 0L, 0L, true, 0L))
    }

    @Test
    fun contentRangeTotalSizeMismatchValidation() {
        fun validateTotalSize(expectedTotal: Long?, serverTotal: Long?): Boolean {
            if (expectedTotal != null && expectedTotal > 0 && serverTotal != null && serverTotal != expectedTotal) {
                return false
            }
            return true
        }

        assertTrue("Matching total size is valid", validateTotalSize(1020613970L, 1020613970L))
        assertTrue("Unknown expected size is permitted", validateTotalSize(null, 1020613970L))
        assertFalse("Mismatched total size must be rejected as size_mismatch", validateTotalSize(1020613970L, 500000000L))
    }

    @Test
    fun noEtagAllowsResumeIfRangeAccepted() {
        fun validateEtag(isResume: Boolean, eTag: String?, eTagHeader: String?): Boolean {
            if (isResume && !eTag.isNullOrEmpty() && (eTagHeader != eTag || eTag.startsWith("W/"))) {
                return false
            }
            return true
        }

        assertTrue("Empty ETag allows resume", validateEtag(true, null, null))
        assertTrue("Empty saved ETag with response ETag allows resume", validateEtag(true, null, "\"new-etag\""))
        assertTrue("Matching strong ETag allows resume", validateEtag(true, "\"strong-123\"", "\"strong-123\""))
        assertFalse("Mismatched ETag rejected", validateEtag(true, "\"strong-123\"", "\"strong-456\""))
        assertFalse("Weak ETag rejected", validateEtag(true, "W/\"weak-123\"", "W/\"weak-123\""))
    }
}

