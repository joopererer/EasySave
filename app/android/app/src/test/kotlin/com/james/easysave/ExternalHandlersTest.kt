package com.james.easysave

import org.junit.Assert.*
import org.junit.Test

class ExternalHandlersTest {
    @Test fun allEntrancesUseLocalInstalledAllowlistWithoutSiteRegistry() {
        for (entry in listOf("share", "clipboard", "bubble", "input")) {
            val lookups = mutableListOf<String>()
            val sent = mutableListOf<Pair<String, String>>()
            assertTrue(entry, ExternalHandlers.route("分享 https://youtu.be/abc123。",
                { pkg -> lookups.add(pkg); true }, { pkg, url -> sent.add(pkg to url) }, { fail("Unexpected guidance") }))
            assertEquals(listOf("com.junkfood.seal"), lookups)
            assertEquals(listOf("com.junkfood.seal" to "https://youtu.be/abc123"), sent)
        }
    }
    @Test fun missingHandlerRoutesToGuidanceWithoutSendingIntentToUninstalledPackage() {
        for (entry in listOf("share", "clipboard", "bubble", "input")) {
            var guidance: String? = null
            assertTrue(entry, ExternalHandlers.route("youtube.com/watch?v=abc",
                { false }, { _, _ -> fail("No installed handler") }, { guidance = it }))
            assertEquals("https://youtube.com/watch?v=abc", guidance)
        }
    }
    @Test fun unregisteredSitesAndSpoofedExternalUrlsNeverReachPackageLookup() {
        for (text in listOf("https://www.bilibili.com/video/BV123", "https://youtube.com.evil.test/watch?v=x",
            "https://user@youtube.com/watch?v=x", "ftp://youtube.com/watch?v=x")) {
            assertFalse(text, ExternalHandlers.route(text, { fail("No lookup"); false }, { _, _ -> fail("No send") }, { fail("No guidance") }))
        }
    }
}
