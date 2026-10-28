package com.james.easysave

/** One process-wide atomic registry shared by both Flutter engines. */
class DownloadClaims {
    private val owners = mutableMapOf<String, String>()
    private val cancelled = mutableSetOf<String>()
    @Synchronized fun reserve(batch: String, keys: List<String>, existing: Map<String, String>): List<String> {
        if (batch in cancelled) return emptyList()
        existing.filterValues { it !in cancelled }.forEach { (key, owner) -> owners.putIfAbsent(key, owner) }
        return keys.filter { key ->
            if (owners[key] == null || owners[key] == batch) { owners[key] = batch; true } else false
        }
    }
    @Synchronized fun release(batch: String) { owners.entries.removeAll { it.value == batch } }
    @Synchronized fun cancelPost(prefix: String): List<String> {
        val batches = owners.filterKeys { it.startsWith(prefix) }.values.distinct()
        cancelled.addAll(batches)
        owners.entries.removeAll { it.value in cancelled }
        return batches
    }
    @Synchronized fun isCancelled(batch: String) = batch in cancelled
}
