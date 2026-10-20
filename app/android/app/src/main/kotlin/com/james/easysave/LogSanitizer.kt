package com.james.easysave

/**
 * Removes sensitive data from anything that is written to logcat.
 *
 * Rules:
 *  - URLs are reduced to `host + path`, so query parameters (xsec_token,
 *    share_id, ...) never reach the log;
 *  - values of cookie / authorization / token / secret-ish keys are replaced
 *    with `<redacted>`;
 *  - long free text (clipboard / share payloads) is never logged verbatim:
 *    only its length and the host of the first URL are kept.
 */
object LogSanitizer {
    private const val REDACTED = "<redacted>"

    private val urlPattern = Regex("""https?://[^\s"'<>]+""")

    private val sensitivePair = Regex(
        """([A-Za-z0-9_.-]*(?:cookie|authorization|auth|token|password|passwd|secret|session|api[_-]?key|sig|signature)[A-Za-z0-9_.-]*)\s*[=:]\s*("[^"]*"|'[^']*'|[^\s,;)]+)""",
        RegexOption.IGNORE_CASE,
    )

    private val bearer = Regex("""\b(Bearer|Basic)\s+[A-Za-z0-9._\-]+""", RegexOption.IGNORE_CASE)

    /** Full sanitizer for log messages. */
    fun scrub(message: String): String {
        var out = message
        out = sensitivePair.replace(out) { m -> "${m.groupValues[1]}=$REDACTED" }
        out = bearer.replace(out, REDACTED)
        out = urlPattern.replace(out) { m -> hostPath(m.value) }
        return out
    }

    /**
     * Summary of a free text payload (clipboard / share text): only the
     * length and the host of the first URL — never the text itself.
     */
    fun summarize(text: String?): String {
        if (text.isNullOrBlank()) return "<empty>"
        val host = urlPattern.find(text)?.value?.let { hostPath(it) } ?: "<no-url>"
        return "len=${text.length} first=$host"
    }

    /** `https://host/path?query#frag` -> `host/path` */
    fun hostPath(url: String): String {
        return try {
            val uri = java.net.URI(url)
            val host = uri.host ?: ""
            if (host.isEmpty()) "<url>" else host + (uri.path ?: "")
        } catch (_: Exception) {
            "<url>"
        }
    }
}
