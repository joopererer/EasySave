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
        val permitted = setOf("referer", "origin", "user-agent", "range")
        val seen = HashSet<String>()
        for ((name, value) in headers) {
            val normalized = name.lowercase(Locale.ROOT)
            if (normalized !in permitted || !seen.add(normalized) ||
                value.any { it == '\r' || it == '\n' || it == '\u0000' }
            ) return Rejection("REQUEST_HEADER_REJECTED", host)
        }
        return null
    }
}
