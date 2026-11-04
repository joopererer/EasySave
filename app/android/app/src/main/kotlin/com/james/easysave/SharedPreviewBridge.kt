package com.james.easysave

import android.content.Context
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import android.os.Handler
import android.os.Looper
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** RAM-only handoff between Dart engines; never persist parsed posts. */
internal class ParsedHandoff(private val now: () -> Long = System::currentTimeMillis) {
    private val values = ArrayDeque<Pair<Long, Map<*, *>>>()
    @Synchronized fun put(value: Map<*, *>) {
        prune()
        val canonical = value["canonical"]
        val previousKeys = values.filter { canonical != null && it.second["canonical"] == canonical }
            .flatMap { (it.second["keys"] as? List<*>) ?: emptyList<Any>() }
        if (canonical != null) values.removeAll { it.second["canonical"] == canonical }
        while (values.size >= 8) values.removeFirst()
        val merged = value.entries.associate { it.key to it.value }.toMutableMap()
        merged["keys"] = (previousKeys + ((value["keys"] as? List<*>) ?: emptyList<Any>())).distinct().takeLast(64)
        values.addLast(now() + 600_000L to merged)
    }
    @Synchronized fun get(key: String): Map<*, *>? {
        prune()
        return values.lastOrNull { (_, value) -> (value["keys"] as? List<*>)?.contains(key) == true }?.second
    }
    @Synchronized fun lookup(key: String): Map<String, Any?> {
        val record = values.lastOrNull { (_, value) -> (value["keys"] as? List<*>)?.contains(key) == true }
            ?: return mapOf("status" to "miss")
        if (record.first <= now()) {
            values.remove(record)
            return mapOf("status" to "expired", "value" to record.second)
        }
        return mapOf("status" to "hit", "value" to record.second)
    }
    private fun prune() { values.removeAll { it.first <= now() } }
}

/** One process-wide cache writer for all Dart engines; filenames contain only SHA-256. */
internal fun thumbnailValid(file: File): Boolean {
    if (file.length() !in 1..10L * 1024 * 1024) return false
    val bytes = file.readBytes()
    if (!thumbnailContainerComplete(bytes)) return false
    val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, options)
    if (options.outWidth <= 0 || options.outHeight <= 0) return false
    return true
}
internal fun thumbnailContainerComplete(bytes: ByteArray): Boolean {
    fun at(index: Int) = bytes[index].toInt() and 255
    if (bytes.size < 12) return false
    if (at(0) == 255 && at(1) == 216) return at(bytes.size - 2) == 255 && at(bytes.size - 1) == 217
    if (at(0) == 137 && at(1) == 80) return bytes.copyOfRange(bytes.size - 8, bytes.size - 4).toString(Charsets.US_ASCII) == "IEND"
    if (bytes.copyOfRange(0, 4).toString(Charsets.US_ASCII) == "RIFF") {
        val size = (4..7).fold(0L) { value, i -> value or (at(i).toLong() shl ((i - 4) * 8)) }
        return size + 8 == bytes.size.toLong()
    }
    return true
}
internal class ThumbnailFiles(private val root: File, private val maxBytes: Long = 64L * 1024 * 1024,
    private val validateImage: (File) -> Boolean = ::thumbnailValid,
    private val now: () -> Long = System::currentTimeMillis) {
    private var cleaned = false
    private fun valid(file: File): Boolean {
        return runCatching { validateImage(file) }.getOrDefault(false)
    }
    @Synchronized fun remove(key: String) {
        if (key.matches(Regex("[a-f0-9]{64}"))) File(root, key).delete()
    }
    @Synchronized fun clean() {
        if (cleaned) return
        root.listFiles()?.filter { it.isFile }?.forEach {
            if (it.name.endsWith(".tmp") || it.lastModified() <= now() || !valid(it)) it.delete()
        }
        cleaned = true
    }
    fun read(key: String): File? {
        if (!key.matches(Regex("[a-f0-9]{64}"))) return null
        val file = File(root, key)
        if (!file.exists() || file.lastModified() <= now()) return null
        return file
    }
    @Synchronized fun write(key: String, bytes: ByteArray, expires: Long): File? {
        require(key.matches(Regex("[a-f0-9]{64}")))
        if (bytes.isEmpty() || bytes.size > 10 * 1024 * 1024 || bytes.size > maxBytes || expires <= now()) return null
        root.mkdirs()
        val file = File(root, key)
        val files = root.listFiles()?.filter { it.isFile && it.name != key }?.sortedBy { it.lastModified() } ?: emptyList()
        var size = files.sumOf { it.length() }
        for (old in files) {
            if (old.lastModified() <= now() || size + bytes.size > maxBytes) {
                size -= old.length(); old.delete()
            }
        }
        val temporary = File(root, "$key.tmp")
        try {
            temporary.writeBytes(bytes)
            if (!valid(temporary)) return null
            check(temporary.renameTo(file))
        } finally { temporary.delete() }
        file.setLastModified(minOf(expires, now() + 10 * 60_000L))
        return file
    }
    @Synchronized fun trim(current: String) {
        val committed = root.listFiles()?.filter { it.name.matches(Regex("[a-f0-9]{64}")) } ?: return
        var size = committed.sumOf { it.length() }
        for (old in committed.sortedBy { it.lastModified() }) {
            if (old.name != current && (old.lastModified() <= now() || size > maxBytes)) {
                size -= old.length(); old.delete()
            }
        }
    }
    fun readPath(path: String): ByteArray? {
        val file = File(path).canonicalFile
        if (file.parentFile != root.canonicalFile) return null
        return read(file.name)?.takeIf { it.length() <= 10 * 1024 * 1024 }?.readBytes()
    }
}

/** A waiter never owns a download: it re-reads the atomic commit, or acquires again. */
internal class ThumbnailFlights {
    private val pending = mutableMapOf<String, MutableList<(Boolean) -> Unit>>()
    @Synchronized fun acquire(key: String, answer: (Boolean) -> Unit) {
        val waiters = pending[key]
        if (waiters == null) { pending[key] = mutableListOf(); answer(true) }
        else waiters.add(answer)
    }
    fun release(key: String) {
        val waiters = synchronized(this) { pending.remove(key) }
        waiters?.forEach { it(false) }
    }
}

internal object SharedPreviewBridge {
    internal val queues = ThumbnailQueues()
    private val posts = ParsedHandoff()
    private var files: ThumbnailFiles? = null
    private var thumbnailChannel: MethodChannel? = null
    private val flights = ThumbnailFlights()
    private val visible = ThumbnailVisibility()
    fun invalidate(key: String) { files?.remove(key); NativeThumbBitmaps.remove(key) }
    fun detach(messenger: BinaryMessenger) { visible.detach(messenger) }
    private fun prefetchIdle(key: String?): Boolean = visible.idle(key)
    fun imageAsync(cacheKey: String?, token: String, label: String, complete: (ByteArray?) -> Unit) {
        queues.read(label, { check(Looper.myLooper() != Looper.getMainLooper()); cacheKey?.let { files?.read(it)?.let { file -> files?.readPath(file.path) } } }) {
            val bytes = it.getOrNull()
            if (bytes != null) complete(bytes) else imageKeyAsync(token, complete)
        }
    }
    fun imageKeyAsync(key: String, complete: (ByteArray?) -> Unit) {
        if (!key.matches(Regex("[a-f0-9]{64}"))) { complete(null); return }
        Handler(Looper.getMainLooper()).post {
            val channel = thumbnailChannel
            if (channel == null) { complete(null); return@post }
            channel.invokeMethod("fetchThumbnail", key, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    val path = result as? String
                    if (path == null) complete(null)
                    else queues.read(key, { check(Looper.myLooper() != Looper.getMainLooper()); files?.readPath(path) }) { complete(it.getOrNull()) }
                }
                override fun error(code: String, message: String?, details: Any?) { complete(null) }
                override fun notImplemented() { complete(null) }
            })
        }
    }
    fun image(path: String): ByteArray? {
        check(Looper.myLooper() != Looper.getMainLooper())
        return files?.readPath(path)
    }
    fun imageKey(key: String): ByteArray? {
        if (!key.matches(Regex("[a-f0-9]{64}"))) return null
        check(Looper.myLooper() != Looper.getMainLooper())
        val latch = CountDownLatch(1)
        var path: String? = null
        Handler(Looper.getMainLooper()).post {
            val channel = thumbnailChannel
            if (channel == null) { latch.countDown(); return@post }
            channel.invokeMethod("fetchThumbnail", key, object : MethodChannel.Result {
                override fun success(result: Any?) { path = result as? String; latch.countDown() }
                override fun error(code: String, message: String?, details: Any?) { latch.countDown() }
                override fun notImplemented() { latch.countDown() }
            })
        }
        if (!latch.await(20, TimeUnit.SECONDS)) return null
        return path?.let { image(it) }
    }
    fun register(context: Context, messenger: BinaryMessenger, background: Boolean = false) {
        if (files == null) {
            files = ThumbnailFiles(File(context.cacheDir, "easysave_thumbnails"))
            queues.write("maintenance", { files!!.clean() }) {}
        }
        val channel = MethodChannel(messenger, "easysave/shared_preview",
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(BinaryMessenger.TaskQueueOptions().setIsSerial(false)))
        if (background) thumbnailChannel = channel
        channel.setMethodCallHandler { call, result ->
            try {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                val label = (args["label"] as? String)?.takeIf { it.matches(Regex("[A-Za-z0-9_:.-]{1,180}")) }
                    ?: args["key"] as? String ?: "maintenance"
                when (call.method) {
                    "putParsed" -> { posts.put(args); result.success(null) }
                    "getParsed" -> result.success(posts.get(args["key"] as String))
                    "lookupParsed" -> result.success(posts.lookup(args["key"] as String))
                    "thumbnailVisibleBegin" -> {
                        visible.begin(args["key"] as String, messenger)
                        result.success(null)
                    }
                    "thumbnailVisibleEnd" -> {
                        visible.end(args["key"] as String, messenger)
                        result.success(null)
                    }
                    "thumbnailPrefetchAllowed" -> {
                        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                        result.success(prefetchIdle(args["key"] as? String) && caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                            cm.restrictBackgroundStatus != ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED))
                    }
                    "thumbnailPrefetchIdle" -> result.success(prefetchIdle(args["key"] as? String))
                    "thumbnailVisible" -> result.success(visible.contains(args["key"] as String))
                    "thumbnailAcquire" -> flights.acquire(args["key"] as String) { result.success(it) }
                    "thumbnailRelease" -> {
                        flights.release(args["key"] as String)
                        result.success(null)
                    }
                    "thumbnailDelete" -> queues.write(args["key"] as String, { files!!.remove(args["key"] as String)
                        NativeThumbBitmaps.remove(args["key"] as String) }) {
                        it.fold({ result.success(null) }) { result.error("PREVIEW_CACHE_IO", "Cache delete failed", null) }
                    }
                    "thumbnailRead" -> {
                        if (args["prefetch"] == true) queues.prefetchReadInfo(label, { files!!.read(args["key"] as String)?.path }) {
                            it.fold(result::success) { result.error("PREVIEW_CACHE_IO", "Cache read failed", null) }
                        } else if (args["timing"] == true) queues.readInfo(label, { files!!.read(args["key"] as String)?.path }) {
                            it.fold(result::success) { result.error("PREVIEW_CACHE_IO", "Cache read failed", null) }
                        } else queues.read(label, { files!!.read(args["key"] as String)?.path }) {
                            it.fold(result::success) { result.error("PREVIEW_CACHE_IO", "Cache read failed", null) }
                        }
                    }
                    "thumbnailDirectory" -> queues.write(label, { File(context.cacheDir, "easysave_thumbnails").path }) {
                        it.fold(result::success) { result.error("PREVIEW_CACHE_IO", "Cache directory failed", null) }
                    }
                    "thumbnailReady" -> queues.write(label, {
                        check(Looper.myLooper() != Looper.getMainLooper())
                        val key = args["key"] as String
                        val file = File(args["path"] as String).canonicalFile
                        val root = File(context.cacheDir, "easysave_thumbnails").canonicalFile
                        require(key.matches(Regex("[a-f0-9]{64}")) && file.parentFile == root && file.name == key)
                        require(file.length() in 1..10L * 1024 * 1024)
                        check(file.setLastModified(System.currentTimeMillis() + 600_000L))
                        files!!.trim(key)
                        null
                    }) {
                        it.fold({ result.success(null) }) { result.error("PREVIEW_CACHE_IO", "Cache ready failed", null) }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("PREVIEW_CACHE_IO", "Preview cache operation failed", null) }
        }
    }
}
