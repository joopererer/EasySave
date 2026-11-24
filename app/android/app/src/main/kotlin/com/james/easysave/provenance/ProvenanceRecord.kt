package com.james.easysave.provenance

/**
 * Data model for provenance records conforming to provenance-spec 0.1.
 * Pure JVM, no Android dependencies.
 */
data class ProvenanceRecord(
    val schema: String = "0.1",
    val assetId: String,
    val capturedAt: String,
    val capturedBy: String,
    val metadataDate: String,
    val sourceUrl: String? = null,
    val platform: String? = null,
    val sourceId: String? = null,
    val itemIndex: Int? = null,
    val itemCount: Int? = null,
    val authorId: String? = null,
    val publishedAt: String? = null,
    val pairId: String? = null,
    val title: String? = null,
    val creator: List<String>? = null,
    val description: String? = null,
    val subject: List<String>? = null,
    val rating: Int? = null,
    val credit: String? = null,
    val aiLabel: String? = null,
    val aiLabelSource: String? = null,
    val digitalSourceType: String? = null,
    val otherFields: Map<String, String> = emptyMap(),
) {
    companion object {
        fun fromJson(json: org.json.JSONObject): ProvenanceRecord {
            val sourceObj = json.optJSONObject("source")
            val creatorsList = if (json.has("creator")) {
                val opt = json.opt("creator")
                if (opt is org.json.JSONArray) {
                    List(opt.length()) { opt.getString(it) }
                } else if (opt is String) {
                    listOf(opt)
                } else null
            } else null

            val subjectList = if (json.has("subject")) {
                val opt = json.opt("subject")
                if (opt is org.json.JSONArray) {
                    List(opt.length()) { opt.getString(it) }
                } else if (opt is String) {
                    listOf(opt)
                } else null
            } else null

            val sUrl = sourceObj?.optString("url")?.ifEmpty { null }
                ?: json.optString("sourceUrl").ifEmpty { json.optString("source_url").ifEmpty { null } }
            val plat = sourceObj?.optString("platform")?.ifEmpty { null }
                ?: json.optString("platform").ifEmpty { null }
            val sId = sourceObj?.optString("id")?.ifEmpty { null }
                ?: json.optString("sourceId").ifEmpty { json.optString("source_id").ifEmpty { null } }
            val itemIdx = if (sourceObj?.has("itemIndex") == true) sourceObj.getInt("itemIndex")
                else if (json.has("itemIndex")) json.getInt("itemIndex")
                else if (json.has("item_index")) json.getInt("item_index")
                else null
            val itemCnt = if (sourceObj?.has("itemCount") == true) sourceObj.getInt("itemCount")
                else if (json.has("itemCount")) json.getInt("itemCount")
                else if (json.has("item_count")) json.getInt("item_count")
                else null
            val authId = sourceObj?.optString("authorId")?.ifEmpty { null }
                ?: json.optString("authorId").ifEmpty { json.optString("author_id").ifEmpty { null } }
            val pubAt = sourceObj?.optString("publishedAt")?.ifEmpty { null }
                ?: json.optString("publishedAt").ifEmpty { json.optString("published_at").ifEmpty { null } }

            return ProvenanceRecord(
                schema = json.optString("schema", "0.1"),
                assetId = json.optString("assetId").ifEmpty { json.optString("asset_id") },
                capturedAt = json.optString("capturedAt").ifEmpty { json.optString("captured_at") },
                capturedBy = json.optString("capturedBy").ifEmpty { json.optString("captured_by") },
                metadataDate = json.optString("metadataDate").ifEmpty { json.optString("metadata_date", json.optString("capturedAt")) },
                sourceUrl = sUrl,
                platform = plat,
                sourceId = sId,
                itemIndex = itemIdx,
                itemCount = itemCnt,
                authorId = authId,
                publishedAt = pubAt,
                pairId = json.optString("pairId").ifEmpty { json.optString("pair_id").ifEmpty { null } },
                title = json.optString("title").ifEmpty { null },
                creator = creatorsList,
                description = json.optString("description").ifEmpty { null },
                subject = subjectList,
                rating = if (json.has("rating")) json.getInt("rating") else null,
                credit = json.optString("credit").ifEmpty { null },
                aiLabel = json.optString("aiLabel").ifEmpty { json.optString("ai_label").ifEmpty { null } },
                aiLabelSource = json.optString("aiLabelSource").ifEmpty { json.optString("ai_label_source").ifEmpty { null } },
                digitalSourceType = json.optString("digitalSourceType").ifEmpty { json.optString("digital_source_type").ifEmpty { null } },
            )
        }

        fun fromMap(map: Map<String, Any?>): ProvenanceRecord {
            return fromJson(org.json.JSONObject(map))
        }

        /**
         * Normalizes an ISO-8601 date string to the canonical format used by provenance_dart
         * (formatDateTimeUtc: YYYY-MM-DDTHH:mm:ssZ without milliseconds if UTC, or with timezone offset).
         */
        fun normalizeDate(raw: String?): String? {
            if (raw == null) return null
            return try {
                val instant = java.time.Instant.parse(raw)
                val zdt = instant.atZone(java.time.ZoneOffset.UTC)
                String.format(
                    java.util.Locale.US,
                    "%04d-%02d-%02dT%02d:%02d:%02dZ",
                    zdt.year,
                    zdt.monthValue,
                    zdt.dayOfMonth,
                    zdt.hour,
                    zdt.minute,
                    zdt.second
                )
            } catch (_: Exception) {
                raw
            }
        }
    }
}

