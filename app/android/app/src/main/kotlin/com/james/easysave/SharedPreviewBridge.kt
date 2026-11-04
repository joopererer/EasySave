package com.james.easysave

import android.content.Context
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
        while (values.size >= 8) values.removeFirst()
        values.addLast(now() + 45_000L to value)
    }
    @Synchronized fun get(key: String): Map<*, *>? {
        prune()
        return values.lastOrNull { (_, value) -> (value["keys"] as? List<*>)?.contains(key) == true }?.second
    }
    private fun prune() { values.removeAll { it.first <= now() } }
}

/** One process-wide cache writer for all Dart engines; filenames contain only SHA-256. */
internal class ThumbnailFiles(private val root: File, private val maxBytes: Long = 64L * 1024 * 1024,
    private val now: () -> Long = System::currentTimeMillis) {
    @Synchronized fun read(key: String): File? {
        if (!key.matches(Regex("[a-f0-9]{64}"))) return null
        val file = File(root, key)
        if (!file.exists() || file.lastModified() <= now()) { file.delete(); return null }
        return file
    }
    @Synchronized fun write(key: String, bytes: ByteArray, expires: Long): File? {
        require(key.matches(Regex("[a-f0-9]{64}")))
        if (bytes.isEmpty() || bytes.size > 10 * 1024 * 1024 || bytes.size > maxBytes || expires <= now()) return null
        root.mkdirs()
        val file = File(root, key)
        file.delete()
        val files = root.listFiles()?.filter { it.isFile }?.sortedBy { it.lastModified() } ?: emptyList()
        var size = files.sumOf { it.length() }
        for (old in files) {
            if (old.lastModified() <= now() || size + bytes.size > maxBytes) {
                size -= old.length(); old.delete()
            }
        }
        val temporary = File(root, "$key.tmp")
        temporary.writeBytes(bytes)
        file.delete()
        check(temporary.renameTo(file))
        file.setLastModified(minOf(expires, now() + 5 * 60_000L))
        return file
    }
    @Synchronized fun readPath(path: String): ByteArray? {
        val file = File(path).canonicalFile
        if (file.parentFile != root.canonicalFile) return null
        return read(file.name)?.takeIf { it.length() <= 10 * 1024 * 1024 }?.readBytes()
    }
}

internal object SharedPreviewBridge {
    private val posts = ParsedHandoff()
    private var files: ThumbnailFiles? = null
    private var thumbnailChannel: MethodChannel? = null
    fun image(path: String) = files?.readPath(path)
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
        if (files == null) files = ThumbnailFiles(File(context.cacheDir, "easysave_thumbnails"))
        val channel = MethodChannel(messenger, "easysave/shared_preview")
        if (background) thumbnailChannel = channel
        channel.setMethodCallHandler { call, result ->
            try {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                when (call.method) {
                    "putParsed" -> { posts.put(args); result.success(null) }
                    "getParsed" -> result.success(posts.get(args["key"] as String))
                    "thumbnailRead" -> result.success(files!!.read(args["key"] as String)?.path)
                    "thumbnailWrite" -> result.success(files!!.write(args["key"] as String,
                        args["bytes"] as ByteArray, (args["expires"] as Number).toLong())?.path)
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("PREVIEW_CACHE_IO", "Preview cache operation failed", null) }
        }
    }
}
