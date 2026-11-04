package com.james.easysave

import java.util.concurrent.Executors
import java.util.concurrent.ExecutorService

/** No download or decoder may run on these disk executors. */
internal class ThumbnailQueues(
    private val timing: (String, Long, Long, String) -> Unit = { queue, wait, io, key ->
        NativeLog.i("ThumbLoad", "event=cache_${if (queue == "write") "control" else "read"} layer=native queue=$queue waitMs=$wait ioMs=$io ms=${wait + io} thread=bg key=$key")
    }
) : AutoCloseable {
    private val reads = Executors.newFixedThreadPool(4)
    private val writes = Executors.newSingleThreadExecutor()
    private val speculativeReads = Executors.newSingleThreadExecutor()
    fun <T> read(key: String, operation: () -> T, complete: (Result<T>) -> Unit) = submit(reads, "read", key, operation, complete)
    fun <T> write(key: String, operation: () -> T, complete: (Result<T>) -> Unit) = submit(writes, "write", key, operation, complete)
    fun readInfo(key: String, operation: () -> String?, complete: (Result<Map<String, Any?>>) -> Unit) =
        submit(reads, "read", key, operation, {}) { result, wait, io ->
            complete(result.map { mapOf("path" to it, "waitMs" to wait, "ioMs" to io) })
        }
    fun prefetchReadInfo(key: String, operation: () -> String?, complete: (Result<Map<String, Any?>>) -> Unit) =
        submit(speculativeReads, "prefetch", key, operation, {}) { result, wait, io ->
            complete(result.map { mapOf("path" to it, "waitMs" to wait, "ioMs" to io) })
        }
    private fun <T> submit(executor: ExecutorService, queue: String, key: String, operation: () -> T, complete: (Result<T>) -> Unit,
        measured: ((Result<T>, Long, Long) -> Unit)? = null) {
        val queued = System.nanoTime()
        executor.execute {
            val start = System.nanoTime()
            val result = runCatching(operation)
            val end = System.nanoTime()
            timing(queue, (start - queued) / 1_000_000, (end - start) / 1_000_000, key)
            measured?.invoke(result, (start - queued) / 1_000_000, (end - start) / 1_000_000)
            complete(result)
        }
    }
    override fun close() { reads.shutdownNow(); writes.shutdownNow(); speculativeReads.shutdownNow() }
}

internal class ThumbnailVisibility {
    private val visible = mutableMapOf<Pair<Any, String>, Int>()
    @Synchronized fun begin(key: String, owner: Any = Unit) { val entry = owner to key; visible[entry] = (visible[entry] ?: 0) + 1 }
    @Synchronized fun end(key: String, owner: Any = Unit) {
        val entry = owner to key
        val remaining = (visible[entry] ?: 1) - 1
        if (remaining <= 0) visible.remove(entry) else visible[entry] = remaining
    }
    @Synchronized fun contains(key: String) = visible.keys.any { it.second == key }
    @Synchronized fun idle(key: String?) = visible.isEmpty() || visible.keys.any { it.second == key }
    @Synchronized fun detach(owner: Any) { visible.keys.removeAll { it.first === owner } }
}

/** Byte-bounded process memory, independent of any panel's lifetime. */
internal class ThumbnailMemory<T>(private val maxBytes: Long, private val weight: (T) -> Long,
    private val now: () -> Long = System::currentTimeMillis) {
    private data class Entry<T>(val value: T, val expires: Long, val bytes: Long)
    private val entries = LinkedHashMap<String, Entry<T>>(16, .75f, true)
    private var bytes = 0L
    @Synchronized fun get(key: String): T? {
        val entry = entries[key] ?: return null
        if (entry.expires <= now()) { entries.remove(key); bytes -= entry.bytes; return null }
        return entry.value
    }
    @Synchronized fun put(key: String, value: T, expires: Long) {
        entries.remove(key)?.let { bytes -= it.bytes }
        val size = weight(value)
        if (size > maxBytes || expires <= now()) return
        entries[key] = Entry(value, expires, size); bytes += size
        val iterator = entries.entries.iterator()
        while (bytes > maxBytes && iterator.hasNext()) { bytes -= iterator.next().value.bytes; iterator.remove() }
    }
    @Synchronized fun removePrefix(prefix: String) {
        val iterator = entries.entries.iterator()
        while (iterator.hasNext()) { val entry = iterator.next(); if (entry.key.startsWith(prefix)) { bytes -= entry.value.bytes; iterator.remove() } }
    }
}
