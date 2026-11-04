package com.james.easysave

import android.media.MediaDataSource
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
    private val field: String,
    private val rejected: (String, String, String, String) -> Unit,
) {
    private val localImagePath = raw?.get("localImagePath") as? String
    private val sharedImageKey = raw?.get("sharedImageKey") as? String
    val requiresAppPreview: Boolean = sharedImageKey == null && localImagePath == null && (raw == null || raw["requiresAppPreview"] == true)
    val url: String = raw?.get("url") as? String ?: ""
    private val headers = raw?.get("headers") as? Map<*, *> ?: emptyMap<Any, Any>()
    private val hosts = raw?.get("mediaHosts") as? List<*> ?: emptyList<Any>()
    private val expiresAtMs = (raw?.get("expiresAtMs") as? Number)?.toLong()
    @Volatile private var pendingRange: String? = null

    val diagnosticHost: String
        get() = runCatching { URI(url).host?.lowercase(Locale.ROOT) }
            .getOrNull()?.takeIf { it.matches(Regex("[a-z0-9.-]{1,253}")) } ?: "unknown"

    val diagnosticHeaderNames: String
        get() = headers.keys.mapNotNull { (it as? String)?.lowercase(Locale.ROOT) }
            .filter { it in setOf("referer", "origin", "user-agent", "range") }
            .sorted().joinToString(",").ifEmpty { "none" }

    internal class Rejected(val code: String, val host: String) : IOException("$code host=$host")

    private fun deny(code: String, host: String, address: String = url): Nothing {
        val safeHost = host.lowercase(Locale.ROOT).takeIf {
            it.matches(Regex("[a-z0-9.:-]{1,253}"))
        } ?: ""
        val shape = when {
            address.isEmpty() -> "empty"
            address.startsWith("//") -> "protocol-relative"
            else -> Regex("^([A-Za-z][A-Za-z0-9+.-]*):").find(address)?.let {
                "scheme=${it.groupValues[1].lowercase(Locale.ROOT)}"
            } ?: "relative"
        }
        rejected(code, safeHost, field, shape)
        throw Rejected(code, safeHost)
    }

    private fun checkedUri(address: String): URI {
        val uri = runCatching { URI(address) }.getOrNull()
            ?: deny("REQUEST_URL_REJECTED", "", address)
        val host = uri.host?.lowercase(Locale.ROOT) ?: ""
        if (uri.scheme?.lowercase(Locale.ROOT) != "https" || host.isEmpty() ||
            uri.rawUserInfo != null || uri.rawAuthority?.contains('@') == true
        ) deny("REQUEST_URL_REJECTED", host, address)
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
                pendingRange?.let { connection.setRequestProperty("Range", it) }
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

    fun readImage(maxBytes: Int = 25 * 1024 * 1024): ByteArray {
        if (sharedImageKey != null) return SharedPreviewBridge.imageKey(sharedImageKey)
            ?: throw IOException("CACHE_MISS")
        if (localImagePath != null) return SharedPreviewBridge.image(localImagePath)
            ?: throw IOException("CACHE_MISS")
        return execute { connection ->
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

    }

    fun readRange(offset: Long, length: Int): ByteArray {
        pendingRange = "bytes=$offset-${offset + length - 1}"
        return try {
            execute { connection ->
                connection.inputStream.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(64 * 1024)
                    var remainingOffset = if (connection.responseCode == 200) offset else 0L
                    while (remainingOffset > 0) {
                        val skipped = input.skip(remainingOffset)
                        if (skipped <= 0) break
                        remainingOffset -= skipped
                    }
                    while (output.size() < length) {
                        val count = input.read(
                            buffer,
                            0,
                            minOf(buffer.size, length - output.size()),
                        )
                        if (count < 0) break
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
            }
        } finally {
            pendingRange = null
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

internal class NativePreviewDataSource(private val request: NativeMediaRequest) : MediaDataSource() {
    override fun getSize(): Long = -1L

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (size <= 0) return 0
        val bytes = request.readRange(position, size)
        if (bytes.isEmpty()) return -1
        bytes.copyInto(buffer, offset)
        return bytes.size
    }

    override fun close() = Unit
}
