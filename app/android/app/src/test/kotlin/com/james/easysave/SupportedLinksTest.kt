package com.james.easysave

import org.junit.Assert.*
import org.junit.Test
import org.junit.Before
import java.io.File

class SupportedLinksTest {
    @Before fun loadGeneratedView() {
        val root = generateSequence(File(System.getProperty("user.dir")!!)) { it.parentFile }
            .first { File(it, "spec/test-vectors").isDirectory }
        SupportedLinks.recognitionOverride = File(root, "app/android/app/src/main/assets/link-recognition.json").readText()
    }

    @Test fun tiktokShareFormats() {
        for (url in listOf("https://www.tiktok.com/@user/video/123", "https://www.tiktok.com/@user/photo/123",
            "https://vm.tiktok.com/abc/", "https://vt.tiktok.com/abc/", "https://www.tiktok.com/t/abc/")) {
            assertTrue(url, SupportedLinks.containsSupportedUrl("分享 $url。"))
        }
    }
    @Test fun hostBoundaries() {
        assertFalse(SupportedLinks.containsSupportedUrl("https://tiktok.com.evil.example/video/123"))
        assertFalse(SupportedLinks.containsSupportedUrl("https://nottiktok.com/video/123"))
        assertFalse(SupportedLinks.containsSupportedUrl(null))
        assertFalse(SupportedLinks.containsSupportedUrl("tiktok.com"))
    }
    @Test fun existingPlatformsRemainSupported() {
        for (url in listOf("https://www.xiaohongshu.com/explore/abc", "https://xhslink.com/abc",
            "https://www.instagram.com/p/abc", "https://x.com/user/status/123", "https://twitter.com/i/status/123", "https://t.co/abc")) {
            assertTrue(url, SupportedLinks.containsSupportedUrl(url))
        }
    }
}
