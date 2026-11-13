package com.bbflight.background_downloader

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import java.net.URI
import java.util.Locale

/** This code is exercised only by EasySave tasks carrying signed-manifest rules. */
object MediaPolicyRedirects {
    data class HostRule(val domain: String, val includeSubdomains: Boolean)
    data class Rejection(val code: String, val host: String)

    fun rules(metaData: String): List<HostRule>? {
        return runCatching {
            val array = Json.parseToJsonElement(metaData).jsonObject["mediaPolicyHosts"]
                ?.jsonArray ?: return null
            array.mapNotNull { value ->
                val entry = value.jsonObject
                val domain = entry["domain"]?.jsonPrimitive?.content?.lowercase(Locale.ROOT)
                    ?: return@mapNotNull null
                if (domain.isBlank()) null else HostRule(domain,
                    entry["includeSubdomains"]?.jsonPrimitive?.booleanOrNull == true)
            }
        }.getOrNull()
    }

    fun reject(raw: String, rules: List<HostRule>): Rejection? {
        val uri = runCatching { URI(raw) }.getOrNull()
        val host = uri?.host?.lowercase(Locale.ROOT)?.takeIf {
            it.matches(Regex("[a-z0-9.:-]{1,253}"))
        } ?: ""
        if (uri == null || uri.scheme?.lowercase(Locale.ROOT) != "https" ||
            uri.rawAuthority?.contains('@') == true || uri.rawUserInfo != null || host.isEmpty()
        ) return Rejection("REQUEST_URL_REJECTED", host)
        if (rules.none { host == it.domain ||
                (it.includeSubdomains && host.endsWith(".${it.domain}"))
            }) return Rejection("REQUEST_HOST_REJECTED", host)
        return null
    }

    fun rejectHeaders(headers: Map<String, String>, host: String): Rejection? {
        val seen = HashSet<String>()
        for ((name, value) in headers) {
            val normalized = name.lowercase(Locale.ROOT)
            if (normalized !in PERMITTED_HEADERS || !seen.add(normalized) ||
                value.any { it == '\r' || it == '\n' || it == '\u0000' }
            ) return Rejection("REQUEST_HEADER_REJECTED", host)
            val allowedValues = PERMITTED_VALUES[normalized]
            if (allowedValues != null &&
                value.lowercase(Locale.ROOT) !in allowedValues
            ) return Rejection("REQUEST_HEADER_REJECTED", host)
        }
        return null
    }

    /**
     * The names a transfer may carry. Mirrors `kAllowedRequestHeaderNames` in
     * `lib/services/media_request_policy.dart`: a Referer/Origin for hot-link
     * protection, the site's User-Agent, a ranged probe and the transfer
     * encoding that keeps a probe and the transfer byte-identical.
     */
    val PERMITTED_HEADERS = setOf("referer", "origin", "user-agent", "range", "accept-encoding")

    /**
     * Values a permitted header may carry when its value changes the bytes on
     * the wire. `identity` is the only encoding a transfer may ask for.
     */
    val PERMITTED_VALUES = mapOf("accept-encoding" to setOf("identity"))
}
