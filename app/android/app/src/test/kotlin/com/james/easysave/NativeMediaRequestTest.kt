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
        ), "imageRequest") { code, host, _, _ -> events.add(code to host) }
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

    // v1.10.3 build 47: the Dart policy whitelists `Accept-Encoding: identity`
    // because every transfer sends it. The native preview fetch re-checks the
    // same list, so it must accept that pair and still refuse any other value.
    @Test fun acceptsIdentityEncodingAndRejectsAnyOther() {
        assertEquals("REQUEST_HEADER_REJECTED" to "tiktok.com",
            rejected("https://tiktok.com/video", mapOf("Accept-Encoding" to "gzip")))
        val request = NativeMediaRequest(
            mapOf(
                "url" to "https://tiktok.com/video",
                "headers" to mapOf("Accept-Encoding" to "identity"),
                "mediaHosts" to hosts,
            ),
            "imageRequest",
        ) { _, _, _, _ -> }
        assertEquals("accept-encoding", request.diagnosticHeaderNames)
    }

    @Test fun rejectionIncludesFieldAndShapeWithoutTheAddress() {
        val events = mutableListOf<List<String>>()
        val request = NativeMediaRequest(
            mapOf("url" to "//example.test/path?secret=hidden", "mediaHosts" to hosts),
            "thumbRequest",
        ) { code, host, field, shape -> events.add(listOf(code, host, field, shape)) }
        assertThrows(NativeMediaRequest.Rejected::class.java) { request.readImage() }
        assertEquals(listOf("REQUEST_URL_REJECTED", "example.test", "thumbRequest", "protocol-relative"), events.single())
    }

    @Test fun playerDiagnosticsContainOnlyHostAndAllowedHeaderNames() {
        val request = NativeMediaRequest(
            mapOf(
                "url" to "https://cdn.tiktok.com/path?token=private",
                "headers" to mapOf("Referer" to "private", "Range" to "private", "Cookie" to "private"),
            ),
            "videoRequest",
        ) { _, _, _, _ -> }
        assertEquals("cdn.tiktok.com", request.diagnosticHost)
        assertEquals("range,referer", request.diagnosticHeaderNames)
    }
}
