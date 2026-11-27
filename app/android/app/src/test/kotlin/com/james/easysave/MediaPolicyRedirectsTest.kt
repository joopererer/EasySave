package com.james.easysave

import com.bbflight.background_downloader.MediaPolicyRedirects as VendorMediaPolicyRedirects
import com.james.easysave.policy.MediaPolicyRedirects as AppMediaPolicyRedirects
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

class MediaPolicyRedirectsTest {
    private val rulesJson = """{"mediaPolicyHosts":[{"domain":"tiktok.com","includeSubdomains":true}]}"""
    private val vendorRules = VendorMediaPolicyRedirects.rules(rulesJson)!!
    private val appRules = AppMediaPolicyRedirects.rules(rulesJson)!!

    private fun findVectorsFile(): File {
        val candidates = listOf(
            File("../../../spec/fixtures/media_request_policy_vectors.json"),
            File("../../spec/fixtures/media_request_policy_vectors.json"),
            File("../spec/fixtures/media_request_policy_vectors.json"),
            File("spec/fixtures/media_request_policy_vectors.json")
        )
        return candidates.firstOrNull { it.exists() }
            ?: throw IllegalStateException("Cannot locate media_request_policy_vectors.json in candidates: ${candidates.map { it.absolutePath }}")
    }

    @Test
    fun runsSharedVectorsOnBothVendorAndAppImplementations() {
        val file = findVectorsFile()
        val json = JSONObject(file.readText())
        val rulesStr = JSONObject().put("mediaPolicyHosts", json.getJSONArray("rules")).toString()
        val vRules = VendorMediaPolicyRedirects.rules(rulesStr)!!
        val aRules = AppMediaPolicyRedirects.rules(rulesStr)!!

        val urlVectors = json.getJSONArray("urlVectors")
        for (i in 0 until urlVectors.length()) {
            val entry = urlVectors.getJSONObject(i)
            val url = entry.getString("url")
            val expectedCode = if (entry.isNull("expectedCode")) null else entry.getString("expectedCode")

            val vRejection = VendorMediaPolicyRedirects.reject(url, vRules)
            val aRejection = AppMediaPolicyRedirects.reject(url, aRules)

            // Both implementations must produce identical results
            assertEquals("URL vector $i ($url) vendor vs app code mismatch", vRejection?.code, aRejection?.code)
            assertEquals("URL vector $i ($url) expected code mismatch", expectedCode, aRejection?.code)
        }

        val headerVectors = json.getJSONArray("headerVectors")
        for (i in 0 until headerVectors.length()) {
            val entry = headerVectors.getJSONObject(i)
            val host = entry.getString("host")
            val expectedCode = if (entry.isNull("expectedCode")) null else entry.getString("expectedCode")
            val headersObj = entry.getJSONObject("headers")
            val headersMap = mutableMapOf<String, String>()
            val keys = headersObj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                headersMap[k] = headersObj.getString(k)
            }

            val vRejection = VendorMediaPolicyRedirects.rejectHeaders(headersMap, host)
            val aRejection = AppMediaPolicyRedirects.rejectHeaders(headersMap, host)

            // Both implementations must produce identical results
            assertEquals("Header vector $i ($headersMap) vendor vs app code mismatch", vRejection?.code, aRejection?.code)
            assertEquals("Header vector $i ($headersMap) expected code mismatch", expectedCode, aRejection?.code)
        }
    }

    @Test
    fun acceptsOnlyDeclaredHostBoundaries() {
        assertNull(AppMediaPolicyRedirects.reject("https://tiktok.com/video", appRules))
        assertNull(AppMediaPolicyRedirects.reject("https://v19-webapp-prime.tiktok.com/video", appRules))
        assertEquals("REQUEST_HOST_REJECTED",
            AppMediaPolicyRedirects.reject("https://tiktok.com.evil.com/video", appRules)?.code)
        assertEquals("REQUEST_HOST_REJECTED",
            AppMediaPolicyRedirects.reject("https://com/video", appRules)?.code)
    }

    @Test
    fun rejectsCredentialsAndDowngrades() {
        assertEquals("REQUEST_URL_REJECTED",
            AppMediaPolicyRedirects.reject("https://user:secret@tiktok.com/video", appRules)?.code)
        assertEquals("REQUEST_URL_REJECTED",
            AppMediaPolicyRedirects.reject("https://@tiktok.com/video", appRules)?.code)
        assertEquals("REQUEST_URL_REJECTED",
            AppMediaPolicyRedirects.reject("http://tiktok.com/video", appRules)?.code)
    }

    @Test
    fun rejectsUnauthorizedHeadersBeforeNetwork() {
        assertEquals("REQUEST_HEADER_REJECTED",
            AppMediaPolicyRedirects.rejectHeaders(mapOf("Cookie" to "secret"), "tiktok.com")?.code)
        assertEquals("REQUEST_HEADER_REJECTED",
            AppMediaPolicyRedirects.rejectHeaders(mapOf("Referer" to "ok\nCookie: secret"), "tiktok.com")?.code)
        assertNull(AppMediaPolicyRedirects.rejectHeaders(mapOf("Range" to "bytes=0-"), "tiktok.com"))
        assertNull(AppMediaPolicyRedirects.rejectHeaders(mapOf("If-Range" to "\"5f8a-12345\""), "tiktok.com"))
        assertNull(AppMediaPolicyRedirects.rejectHeaders(mapOf("if-range" to "W/\"weak-etag-1\""), "tiktok.com"))
        assertNull(AppMediaPolicyRedirects.rejectHeaders(mapOf("If-Range" to "Wed, 21 Oct 2015 07:28:00 GMT"), "tiktok.com"))
        assertEquals("REQUEST_HEADER_REJECTED",
            AppMediaPolicyRedirects.rejectHeaders(mapOf("If-Range" to "unquoted-token"), "tiktok.com")?.code)
        assertEquals("REQUEST_HEADER_REJECTED",
            AppMediaPolicyRedirects.rejectHeaders(mapOf("If-Range" to "\"etag\"\nInjected: true"), "tiktok.com")?.code)
    }

    @Test
    fun acceptsTheUnifiedTransferHeadersWithIdentityEncoding() {
        assertNull(AppMediaPolicyRedirects.rejectHeaders(
            mapOf(
                "User-Agent" to "Mozilla/5.0",
                "Accept-Encoding" to "identity",
                "Referer" to "https://www.xiaohongshu.com/",
                "Range" to "bytes=0-0",
            ),
            "sns-video-zl.xhscdn.com",
        ))
        assertNull(AppMediaPolicyRedirects.rejectHeaders(
            mapOf("accept-encoding" to "IDENTITY"), "scontent-fra3-1.cdninstagram.com"))
    }

    @Test
    fun rejectsAnEncodingItNeverAskedFor() {
        for (value in listOf("gzip", "gzip, identity", "br", "", "identity ")) {
            assertEquals("REQUEST_HEADER_REJECTED",
                AppMediaPolicyRedirects.rejectHeaders(
                    mapOf("Accept-Encoding" to value), "video.twimg.com")?.code)
        }
    }

    @Test
    fun absentPolicyMetadataDoesNotImplyAuthorization() {
        assertNull(AppMediaPolicyRedirects.rules("{}"))
        assertNotNull(AppMediaPolicyRedirects.rules(
            """{"mediaPolicyHosts":[{"domain":"tiktok.com","includeSubdomains":true}]}"""
        ))
    }
}
