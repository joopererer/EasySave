package com.james.easysave

import com.bbflight.background_downloader.MediaPolicyRedirects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test

class MediaPolicyRedirectsTest {
    private val rules = MediaPolicyRedirects.rules(
        """{"mediaPolicyHosts":[{"domain":"tiktok.com","includeSubdomains":true}]}"""
    )!!

    @Test fun acceptsOnlyDeclaredHostBoundaries() {
        assertNull(MediaPolicyRedirects.reject("https://tiktok.com/video", rules))
        assertNull(MediaPolicyRedirects.reject("https://v19-webapp-prime.tiktok.com/video", rules))
        assertEquals("REQUEST_HOST_REJECTED",
            MediaPolicyRedirects.reject("https://tiktok.com.evil.com/video", rules)?.code)
        assertEquals("REQUEST_HOST_REJECTED",
            MediaPolicyRedirects.reject("https://com/video", rules)?.code)
    }

    @Test fun rejectsCredentialsAndDowngrades() {
        assertEquals("REQUEST_URL_REJECTED",
            MediaPolicyRedirects.reject("https://user:secret@tiktok.com/video", rules)?.code)
        assertEquals("REQUEST_URL_REJECTED",
            MediaPolicyRedirects.reject("https://@tiktok.com/video", rules)?.code)
        assertEquals("REQUEST_URL_REJECTED",
            MediaPolicyRedirects.reject("http://tiktok.com/video", rules)?.code)
    }

    @Test fun rejectsUnauthorizedHeadersBeforeNetwork() {
        assertEquals("REQUEST_HEADER_REJECTED",
            MediaPolicyRedirects.rejectHeaders(mapOf("Cookie" to "secret"), "tiktok.com")?.code)
        assertEquals("REQUEST_HEADER_REJECTED",
            MediaPolicyRedirects.rejectHeaders(mapOf("Referer" to "ok\nCookie: secret"), "tiktok.com")?.code)
        assertNull(MediaPolicyRedirects.rejectHeaders(mapOf("Range" to "bytes=0-"), "tiktok.com"))
    }

    // v1.10.3 build 47: every background transfer carries the same two headers
    // the Dart side adds, so `Accept-Encoding: identity` must survive this
    // check. Anything the policy does not declare still may not pass.
    @Test fun acceptsTheUnifiedTransferHeadersWithIdentityEncoding() {
        assertNull(MediaPolicyRedirects.rejectHeaders(
            mapOf(
                "User-Agent" to "Mozilla/5.0",
                "Accept-Encoding" to "identity",
                "Referer" to "https://www.xiaohongshu.com/",
                "Range" to "bytes=0-0",
            ),
            "sns-video-zl.xhscdn.com",
        ))
        assertNull(MediaPolicyRedirects.rejectHeaders(
            mapOf("accept-encoding" to "IDENTITY"), "scontent-fra3-1.cdninstagram.com"))
    }

    @Test fun rejectsAnEncodingItNeverAskedFor() {
        for (value in listOf("gzip", "gzip, identity", "br", "", "identity ")) {
            assertEquals("REQUEST_HEADER_REJECTED",
                MediaPolicyRedirects.rejectHeaders(
                    mapOf("Accept-Encoding" to value), "video.twimg.com")?.code)
        }
    }

    @Test fun absentPolicyMetadataDoesNotImplyAuthorization() {
        assertNull(MediaPolicyRedirects.rules("{}"))
        assertNotNull(MediaPolicyRedirects.rules(
            """{"mediaPolicyHosts":[{"domain":"tiktok.com","includeSubdomains":true}]}"""
        ))
    }
}
