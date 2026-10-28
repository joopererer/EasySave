package com.james.easysave

import java.net.URI

/** Shared guard for share, bubble and tile entry points; Dart resolves short links. */
object SupportedLinks {
    private val domains = setOf(
        "xiaohongshu.com", "rednote.com", "xhslink.com", "xhslink.cn", "xhs.cn",
        "instagram.com", "instagr.am", "x.com", "twitter.com", "t.co", "tiktok.com"
    )
    private val urls = Regex("""https?://[^\s<>"'，。！？；：）】”　]+|(?<![a-zA-Z0-9_@./:-])(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:[/\?#][^\s<>"'，。！？；：）】”　]*)?""", RegexOption.IGNORE_CASE)

    fun extractUrls(text: String?): List<String> = if (text == null) emptyList() else
        urls.findAll(text).mapNotNull { match ->
            val raw = match.value.trimEnd(')', ']', '}', ',', '.', ';', '!', '?')
            val normalized = if (raw.contains("://")) raw else "https://$raw"
            val uri = runCatching { URI(normalized) }.getOrNull()
            val host = uri?.host?.lowercase()
            if (uri?.scheme?.lowercase() in setOf("http", "https") && uri?.userInfo == null &&
                host != null && domains.any { host == it || host.endsWith(".$it") }) normalized else null
        }.distinct().toList()

    fun containsSupportedUrl(text: String?): Boolean =
        extractUrls(text).isNotEmpty()
}
