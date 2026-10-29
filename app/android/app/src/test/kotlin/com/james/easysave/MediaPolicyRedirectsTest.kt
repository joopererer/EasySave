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

    @Test fun absentPolicyMetadataDoesNotImplyAuthorization() {
        assertNull(MediaPolicyRedirects.rules("{}"))
        assertNotNull(MediaPolicyRedirects.rules(
            """{"mediaPolicyHosts":[{"domain":"tiktok.com","includeSubdomains":true}]}"""
        ))
    }
}
