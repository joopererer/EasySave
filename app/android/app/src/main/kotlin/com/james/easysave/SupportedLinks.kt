package com.james.easysave

import java.net.URI

/** Shared guard for share, bubble and tile entry points; Dart resolves short links. */
object SupportedLinks {
    private val domains = setOf(
        "xiaohongshu.com", "rednote.com", "xhslink.com", "xhslink.cn", "xhs.cn",
        "instagram.com", "instagr.am", "x.com", "twitter.com", "t.co", "tiktok.com"
    )
    private val urls = Regex("https?://[^\\s<>\"'，。]+", RegexOption.IGNORE_CASE)

    fun containsSupportedUrl(text: String?): Boolean =
        text != null && urls.findAll(text).any { match ->
            val host = runCatching { URI(match.value.trimEnd(')', ']', '}', ',', '.', ';')).host?.lowercase() }.getOrNull()
            host != null && domains.any { host == it || host.endsWith(".$it") }
        }
}
