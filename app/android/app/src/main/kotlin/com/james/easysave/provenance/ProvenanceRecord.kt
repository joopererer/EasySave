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

