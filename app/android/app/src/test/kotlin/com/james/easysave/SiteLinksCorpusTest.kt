package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class SiteLinksCorpusTest {
    @Test fun sharedDartKotlinCorpus() {
        val root = generateSequence(File(System.getProperty("user.dir")!!)) { it.parentFile }
            .first { File(it, "spec/test-vectors/site-links.json").isFile }
        val viewText = File(root, "app/android/app/src/main/assets/link-recognition.json").readText()
        val view = JSONObject(viewText)
        SupportedLinks.recognitionOverride = viewText
        val cases = JSONArray(File(root, "spec/test-vectors/site-links.json").readText())
        for (i in 0 until cases.length()) {
            val row = cases.getJSONObject(i)
            val text = row.getString("text")
            val first = SupportedLinks.extractUrls(text).firstOrNull()
            val expected = if (row.isNull("siteId")) null else row.getString("siteId")
            assertEquals(text, expected, first?.let { SupportedLinks.siteId(it, view) })
        }
    }

    @Test fun invalidCacheUsesGeneratedBuiltinButValidCacheTakesPriority() {
        val root = generateSequence(File(System.getProperty("user.dir")!!)) { it.parentFile }
            .first { File(it, "spec/test-vectors/site-links.json").isFile }
        val builtin = File(root, "app/android/app/src/main/assets/link-recognition.json").readText()
        val fallback = SupportedLinks.viewFromSources("{broken") { builtin }!!
        assertEquals("x", SupportedLinks.siteId("https://x.com/user/status/123", fallback))
        val empty = SupportedLinks.viewFromSources("{\"sites\":[]}") { error("Should not read builtin") }!!
        assertEquals(null, SupportedLinks.siteId("https://x.com/user/status/123", empty))
    }
}
