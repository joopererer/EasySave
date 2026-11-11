package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.zip.ZipFile

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

    @Test fun packagedApkRecognitionViewMatchesSharedCorpus() {
        val root = generateSequence(File(System.getProperty("user.dir")!!)) { it.parentFile }
            .first { File(it, "spec/test-vectors/site-links.json").isFile }
        val apk = File(root, "app/build/app/outputs/flutter-apk/app-debug.apk")
        require(apk.isFile) { "Build the debug APK before running this test" }
        val viewText = ZipFile(apk).use { zip ->
            val entry = requireNotNull(zip.getEntry("assets/link-recognition.json"))
            zip.getInputStream(entry).bufferedReader().use { it.readText() }
        }
        val view = requireNotNull(SupportedLinks.viewFromSources(null) { viewText })
        val cases = JSONArray(File(root, "spec/test-vectors/site-links.json").readText())
        SupportedLinks.recognitionOverride = viewText
        for (i in 0 until cases.length()) {
            val row = cases.getJSONObject(i)
            val first = SupportedLinks.extractUrls(row.getString("text")).firstOrNull()
            val expected = if (row.isNull("siteId")) null else row.getString("siteId")
            assertEquals(row.getString("text"), expected, first?.let { SupportedLinks.siteId(it, view) })
        }
    }

    @Test fun invalidCacheUsesGeneratedBuiltinButValidCacheTakesPriority() {
        val root = generateSequence(File(System.getProperty("user.dir")!!)) { it.parentFile }
            .first { File(it, "spec/test-vectors/site-links.json").isFile }
        val builtin = File(root, "app/android/app/src/main/assets/link-recognition.json").readText()
        val fallback = SupportedLinks.viewFromSources("{broken") { builtin }!!
        assertEquals("x", SupportedLinks.siteId("https://x.com/user/status/123", fallback))
        val empty = SupportedLinks.viewFromSources("{\"sites\":[]}") { builtin }!!
        assertEquals("x", SupportedLinks.siteId("https://x.com/user/status/123", empty))
        val activatedEmpty = SupportedLinks.viewFromSources("{\"sites\":[],\"activated\":true}") {
            error("Should not read builtin")
        }!!
        assertEquals(null, SupportedLinks.siteId("https://x.com/user/status/123", activatedEmpty))
    }
}
