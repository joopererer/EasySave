package com.james.easysave.policy

import org.json.JSONObject
import java.net.URI
import java.util.Locale

/**
 * 传输服务与媒体请求的策略重定向校验（从 vendor/background_downloader 复制）。
 *
 * 每一跳发包前用 policy 校验目标域名和请求头：
 * 不在白名单的直接终止，原因 policy_rejected。
 */
object MediaPolicyRedirects {
    data class HostRule(val domain: String, val includeSubdomains: Boolean)
    data class Rejection(val code: String, val host: String)

    fun rules(metaData: String): List<HostRule>? {
        return runCatching {
            val json = JSONObject(metaData)
            val array = json.optJSONArray("mediaPolicyHosts") ?: return null
            val list = mutableListOf<HostRule>()
            for (i in 0 until array.length()) {
                val entry = array.optJSONObject(i) ?: continue
                val domain = entry.optString("domain").lowercase(Locale.ROOT).trim()
                if (domain.isNotEmpty()) {
                    list.add(HostRule(domain, entry.optBoolean("includeSubdomains", false)))
                }
            }
            list.ifEmpty { null }
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
            if (normalized == "if-range" && !isPermittedIfRange(value)) {
                return Rejection("REQUEST_HEADER_REJECTED", host)
            }
        }
        return null
    }

    private val IF_RANGE_REGEX = Regex(
        """^(?:(?:W/)?"[^"\r\n\u0000]{1,256}"|[A-Za-z]{3},\s+\d{1,2}\s+[A-Za-z]{3}\s+\d{4}\s+\d{2}:\d{2}:\d{2}\s+GMT)$"""
    )

    fun isPermittedIfRange(value: String): Boolean = IF_RANGE_REGEX.matches(value)

    val PERMITTED_HEADERS = setOf("referer", "origin", "user-agent", "range", "accept-encoding", "if-range")

    val PERMITTED_VALUES = mapOf("accept-encoding" to setOf("identity"))
}

