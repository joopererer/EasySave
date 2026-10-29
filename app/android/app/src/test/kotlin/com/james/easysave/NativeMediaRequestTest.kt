package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class NativeMediaRequestTest {
    private val hosts = listOf(mapOf("domain" to "tiktok.com", "includeSubdomains" to true))

    private fun rejected(url: String, headers: Map<String, String> = emptyMap()): Pair<String, String> {
        val events = mutableListOf<Pair<String, String>>()
        val request = NativeMediaRequest(mapOf(
            "url" to url, "headers" to headers, "mediaHosts" to hosts,
        )) { code, host -> events.add(code to host) }
        assertThrows(NativeMediaRequest.Rejected::class.java) { request.readImage() }
        return events.single()
    }

    @Test fun deniesSpoofedHostWithoutPathOrQuery() {
        assertEquals("REQUEST_HOST_REJECTED" to "tiktok.com.evil.com",
            rejected("https://tiktok.com.evil.com/private?token=secret"))
    }

    @Test fun deniesUserInfoAndHttp() {
        assertEquals("REQUEST_URL_REJECTED" to "tiktok.com",
            rejected("https://user:secret@tiktok.com/video"))
        assertEquals("REQUEST_URL_REJECTED" to "tiktok.com",
            rejected("http://tiktok.com/video"))
    }

    @Test fun deniesInjectedHeaders() {
        assertEquals("REQUEST_HEADER_REJECTED" to "tiktok.com",
            rejected("https://tiktok.com/video", mapOf("Cookie" to "secret")))
        assertEquals("REQUEST_HEADER_REJECTED" to "tiktok.com",
            rejected("https://tiktok.com/video", mapOf("Referer" to "ok\r\nCookie: secret")))
    }
}
