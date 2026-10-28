package com.james.easysave

import org.junit.Assert.*
import org.junit.Test

class SchemelessLinksTest {
    @Test fun knownBareLinksNormalizeAcrossEntryPoints() {
        for (url in listOf("vm.tiktok.com/xxx", "xhslink.cn/o/xxx", "www.instagram.com/p/xxx")) {
            assertEquals(listOf("https://$url"), SupportedLinks.extractUrls("分享：$url。"))
            assertTrue(SupportedLinks.containsSupportedUrl(url))
            assertEquals(listOf("https://$url"), SupportedLinks.extractUrls("$url https://$url"))
        }
    }
    @Test fun lookalikesEmailsAndEmbeddedDomainsStayRejected() {
        for (value in listOf("普通文字", "notxhslink.cn/o/a", "xhslink.cn.evil.com/o/a",
            "user@xhslink.cn/o/a", "evil.com/xhslink.cn/o/a", "ftp://xhslink.cn/o/a")) {
            assertFalse(value, SupportedLinks.containsSupportedUrl(value))
        }
    }
}
