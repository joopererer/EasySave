package com.james.easysave

import org.junit.Assert.*
import org.junit.Test

class SupportedLinksTest {
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
        assertTrue(SupportedLinks.containsSupportedUrl("tiktok.com"))
    }
    @Test fun existingPlatformsRemainSupported() {
        for (host in listOf("www.xiaohongshu.com", "xhslink.com", "www.instagram.com", "x.com", "twitter.com", "t.co")) {
            assertTrue(SupportedLinks.containsSupportedUrl("https://$host/post"))
        }
    }
}
