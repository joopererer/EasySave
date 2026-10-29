package com.james.easysave

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.Locale

/** Native consumer of the Dart policy's cookie-free request declaration. */
internal class NativeMediaRequest(
    private val raw: Map<*, *>?,
    private val rejected: (String, String) -> Unit,
) {
    val requiresAppPreview: Boolean = raw == null || raw["requiresAppPreview"] == true
    val url: String = raw?.get("url") as? String ?: ""
    private val headers = raw?.get("headers") as? Map<*, *> ?: emptyMap<Any, Any>()
    private val hosts = raw?.get("mediaHosts") as? List<*> ?: emptyList<Any>()
    private val expiresAtMs = (raw?.get("expiresAtMs") as? Number)?.toLong()

    internal class Rejected(val code: String, val host: String) : IOException("$code host=$host")

    private fun deny(code: String, host: String): Nothing {
        val safeHost = host.lowercase(Locale.ROOT).takeIf {
            it.matches(Regex("[a-z0-9.:-]{1,253}"))
        } ?: ""
        rejected(code, safeHost)
        throw Rejected(code, safeHost)
    }

    private fun checkedUri(address: String): URI {
        val uri = runCatching { URI(address) }.getOrNull()
            ?: deny("REQUEST_URL_REJECTED", "")
        val host = uri.host?.lowercase(Locale.ROOT) ?: ""
        if (uri.scheme?.lowercase(Locale.ROOT) != "https" || host.isEmpty() ||
            uri.rawUserInfo != null || uri.rawAuthority?.contains('@') == true
        ) deny("REQUEST_URL_REJECTED", host)
        val accepted = hosts.any { rule ->
            val map = rule as? Map<*, *> ?: return@any false
            val domain = (map["domain"] as? String)?.lowercase(Locale.ROOT) ?: return@any false
            host == domain || (map["includeSubdomains"] == true && host.endsWith(".$domain"))
        }
        if (!accepted) deny("REQUEST_HOST_REJECTED", host)
        if (expiresAtMs != null && expiresAtMs <= System.currentTimeMillis()) {
            deny("REQUEST_EXPIRED", host)
        }
        return uri
    }

    private fun checkedHeaders(host: String): Map<String, String> {
        val names = mapOf(
            "referer" to "Referer", "origin" to "Origin",
            "user-agent" to "User-Agent", "range" to "Range",
        )
        val result = LinkedHashMap<String, String>()
        for ((rawName, rawValue) in headers) {
            val name = names[(rawName as? String)?.lowercase(Locale.ROOT)]
                ?: deny("REQUEST_HEADER_REJECTED", host)
            val value = rawValue as? String ?: deny("REQUEST_HEADER_REJECTED", host)
            if (value.any { it == '\r' || it == '\n' || it == '\u0000' } || result.containsKey(name)) {
                deny("REQUEST_HEADER_REJECTED", host)
            }
            result[name] = value
        }
        return result
    }

    private fun <T> execute(read: (HttpURLConnection) -> T): T {
        if (requiresAppPreview) deny("REQUEST_COOKIE_REQUIRED", "")
        var current = url
        for (hop in 0..5) {
            val uri = checkedUri(current)
            val headers = checkedHeaders(uri.host)
            val connection = URL(current).openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 8000
                connection.readTimeout = 12000
                for ((name, value) in headers) connection.setRequestProperty(name, value)
                val status = connection.responseCode
                if (status in 300..399) {
                    val location = connection.getHeaderField("Location")
                    if (location == null || hop == 5) deny("REQUEST_REDIRECT_REJECTED", uri.host)
                    current = runCatching { uri.resolve(location).toString() }.getOrNull()
                        ?: deny("REQUEST_REDIRECT_REJECTED", uri.host)
                    continue
                }
                if (status !in 200..299) throw IOException("HTTP_$status")
                return read(connection)
            } finally {
                connection.disconnect()
            }
        }
        deny("REQUEST_REDIRECT_REJECTED", "")
    }

    fun readImage(maxBytes: Int = 25 * 1024 * 1024): ByteArray = execute { connection ->
        connection.inputStream.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                if (output.size() + count > maxBytes) throw IOException("IMAGE_TOO_LARGE")
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }

    fun writeVideo(file: File, maxBytes: Long = 250L * 1024 * 1024) = execute { connection ->
        var total = 0L
        file.outputStream().use { output ->
            connection.inputStream.use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > maxBytes) throw IOException("VIDEO_TOO_LARGE")
                    output.write(buffer, 0, count)
                }
            }
        }
    }
}
