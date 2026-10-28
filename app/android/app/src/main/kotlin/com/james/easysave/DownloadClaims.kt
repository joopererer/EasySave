package com.james.easysave

/** One process-wide atomic registry shared by both Flutter engines. */
class DownloadClaims {
    private val owners = mutableMapOf<String, String>()
    @Synchronized fun reserve(batch: String, keys: List<String>, existing: Map<String, String>): List<String> {
        existing.forEach { (key, owner) -> owners.putIfAbsent(key, owner) }
        return keys.filter { key ->
            if (owners[key] == null || owners[key] == batch) { owners[key] = batch; true } else false
        }
    }
    @Synchronized fun release(batch: String) { owners.entries.removeAll { it.value == batch } }
}
