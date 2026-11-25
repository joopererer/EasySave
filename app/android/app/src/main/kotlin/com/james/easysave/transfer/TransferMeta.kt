package com.james.easysave.transfer

import org.json.JSONObject
import java.io.File

/**
 * 传输任务元数据文件持久化（<jobId>.meta）。
 *
 * 规范：
 * - 存储在 transfers/<jobId>.meta（JSON 格式）
 * - 记录字段：url, total, etag, lastModified, mime, sniff, policyKey
 * - 严禁写入 cookie、token 或 query 凭据。
 */
data class TransferMeta(
    val url: String,
    val total: Long = -1L,
    val etag: String? = null,
    val lastModified: String? = null,
    val mime: String? = null,
    val sniff: String? = null,
    val policyKey: String? = null,
    val provenance: Map<String, Any?>? = null,
    val requiresCookie: Boolean = false,
) {
    fun toJson(): String {
        val obj = JSONObject()
        obj.put("url", url)
        obj.put("total", total)
        if (etag != null) obj.put("etag", etag)
        if (lastModified != null) obj.put("lastModified", lastModified)
        if (mime != null) obj.put("mime", mime)
        if (sniff != null) obj.put("sniff", sniff)
        if (policyKey != null) obj.put("policyKey", policyKey)
        if (provenance != null) obj.put("provenance", JSONObject(provenance))
        if (requiresCookie) obj.put("requiresCookie", true)
        return obj.toString()
    }

    companion object {
        fun fromJson(jsonStr: String): TransferMeta? {
            return runCatching {
                val obj = JSONObject(jsonStr)
                val provMap = if (obj.has("provenance")) {
                    val pObj = obj.optJSONObject("provenance")
                    pObj?.let { jsonToMap(it) }
                } else null
                TransferMeta(
                    url = obj.optString("url", ""),
                    total = obj.optLong("total", -1L),
                    etag = if (obj.has("etag")) obj.optString("etag") else null,
                    lastModified = if (obj.has("lastModified")) obj.optString("lastModified") else null,
                    mime = if (obj.has("mime")) obj.optString("mime") else null,
                    sniff = if (obj.has("sniff")) obj.optString("sniff") else null,
                    policyKey = if (obj.has("policyKey")) obj.optString("policyKey") else null,
                    provenance = provMap,
                    requiresCookie = obj.optBoolean("requiresCookie", false),
                )
            }.getOrNull()
        }

        private fun jsonToMap(obj: JSONObject): Map<String, Any?> {
            val map = mutableMapOf<String, Any?>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val value = obj.opt(key)
                map[key] = when (value) {
                    is JSONObject -> jsonToMap(value)
                    is org.json.JSONArray -> {
                        List(value.length()) { i ->
                            val item = value.opt(i)
                            if (item is JSONObject) jsonToMap(item) else item
                        }
                    }
                    JSONObject.NULL -> null
                    else -> value
                }
            }
            return map
        }

        fun read(file: File): TransferMeta? {
            if (!file.exists()) return null
            return runCatching { fromJson(file.readText()) }.getOrNull()
        }

        fun write(file: File, meta: TransferMeta) {
            val parent = file.parentFile
            if (parent != null && !parent.exists()) parent.mkdirs()
            file.writeText(meta.toJson())
        }
    }
}

