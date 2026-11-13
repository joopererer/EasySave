package com.james.easysave

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.util.concurrent.Executors

/**
 * MediaStore reads that need no Activity, shared by the foreground and the
 * overlay (background) engine: header bytes, album of a file, and the index of
 * EasySave's albums used to decide which post items are already saved.
 *
 * Without read permission, Android 10+ MediaStore still returns the files this
 * app created (OWNER_PACKAGE_NAME), so EasySave's own saves stay visible.
 */
class MediaStoreBridge(private val context: Context) {
    companion object {
        const val CHANNEL = "easysave/media"

        /** Most bytes one header decision may read from one file. */
        const val MAX_READ_BYTES = 256 * 1024

        /**
         * A pool of its own for bounded header reads: never the decode probe's
         * executor (a stuck decode lives there) and never the disk executors
         * used by the album scan.
         */
        private val headerPool = Executors.newFixedThreadPool(2) { runnable ->
            Thread(runnable, "easysave-header-read").apply { isDaemon = true }
        }

        /** Background engine: no Activity, so deletes and write grants are refused. */
        fun register(context: Context, messenger: BinaryMessenger) {
            val bridge = MediaStoreBridge(context.applicationContext)
            MethodChannel(messenger, CHANNEL, StandardMethodCodec.INSTANCE,
                messenger.makeBackgroundTaskQueue()).setMethodCallHandler { call, result ->
                if (!bridge.handle(call, result)) {
                    result.error("FOREGROUND_REQUIRED", "Open the App for this action", null)
                }
            }
        }

        /**
         * Read permission as granted by the system, without photo_manager (whose
         * permission query needs an Activity). Pure for unit tests.
         */
        fun permissionState(sdk: Int, granted: (String) -> Boolean): String = when {
            sdk >= 33 && granted(Manifest.permission.READ_MEDIA_IMAGES) &&
                granted(Manifest.permission.READ_MEDIA_VIDEO) -> "granted"
            sdk >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> "partial"
            sdk >= 33 -> "denied"
            granted(Manifest.permission.READ_EXTERNAL_STORAGE) -> "granted"
            else -> "denied"
        }

        /** Selection over BUCKET_DISPLAY_NAME for the given album names. */
        fun bucketSelection(count: Int): String =
            "LOWER(bucket_display_name) IN (" +
                List(count) { "?" }.joinToString(",") + ")"
    }

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "readMediaHeader" -> readMediaHeader(call, result)
            "queryMediaAlbum" -> queryMediaAlbum(call, result)
            "scanFile" -> scanFile(call, result)
            "savedMediaIndex" -> savedMediaIndex(call, result)
            "storageInfo" -> storageInfo(result)
            "mediaSize" -> mediaSize(call, result)
            "mediaSizes" -> mediaSizes(call, result)
            "probeImageDecodable" -> probeImageDecodable(call, result)
            "probeMediaDecodable" -> probeMediaDecodable(call, result)
            "apiLevel" -> result.success(Build.VERSION.SDK_INT)
            "readMediaBytes" -> readMediaBytes(call, result)
            "mediaDuration" -> mediaDuration(call, result)
            else -> return false
        }
        return true
    }

    /**
     * Probes one app-private still with the platform decoders. Never reads a
     * path outside this app's own storage: the self-check and the import gate
     * only ever check files EasySave itself wrote.
     */
    private fun probeImageDecodable(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null || path.isBlank()) {
            result.error("bad_args", "path required", null)
            return
        }
        val file = try {
            File(path).canonicalFile
        } catch (e: Exception) {
            result.error("path_rejected", "unresolvable path", null)
            return
        }
        if (!insideAppStorage(file)) {
            result.error("path_rejected", "path outside app storage", null)
            return
        }
        replyOnMain(result) {
            ImageDecodeProbe.probeFile(file).toMap() + mapOf("bytes" to file.length())
        }
    }

    /** Probes an album still by MediaStore id; read-only, never deletes. */
    private fun probeMediaDecodable(call: MethodCall, result: MethodChannel.Result) {
        val mediaId = call.argument<String>("id")?.toLongOrNull()
        if (mediaId == null) {
            result.error("bad_args", "id must be a numeric media id", null)
            return
        }
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, mediaId,
        )
        replyOnMain(result) {
            ImageDecodeProbe.probeUri(context.contentResolver, uri).toMap() +
                mapOf("id" to mediaId.toString())
        }
    }

    /**
     * A bounded prefix of one saved file's bytes, for header-only decisions
     * (a HEIF alpha auxiliary image is read from `meta`, never decoded).
     *
     * Reads at most [MAX_READ_BYTES] and runs on its own I/O executor: it must
     * never queue behind a stuck decode, and it must never block the platform
     * thread. Nothing is written, moved or deleted.
     */
    private fun readMediaBytes(call: MethodCall, result: MethodChannel.Result) {
        val mediaId = call.argument<String>("id")?.toLongOrNull()
        if (mediaId == null) {
            result.error("bad_args", "id must be a numeric media id", null)
            return
        }
        val maxBytes = (call.argument<Int>("maxBytes") ?: MAX_READ_BYTES)
            .coerceIn(1, MAX_READ_BYTES)
        val mimeType = call.argument<String>("mimeType")
        val collection = if (mimeType?.startsWith("video/") == true) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val uri = ContentUris.withAppendedId(collection, mediaId)
        val main = Handler(Looper.getMainLooper())
        headerPool.execute {
            val bytes = try {
                context.contentResolver.openInputStream(uri)?.use { input ->
                    val buffer = ByteArray(maxBytes)
                    var total = 0
                    while (total < maxBytes) {
                        val read = input.read(buffer, total, maxBytes - total)
                        if (read <= 0) break
                        total += read
                    }
                    buffer.copyOf(total)
                }
            } catch (e: Exception) {
                null
            }
            main.post { result.success(bytes) }
        }
    }

    /** MediaStore DURATION in ms of a saved video, or null when not visible. */
    private fun mediaDuration(call: MethodCall, result: MethodChannel.Result) {        val mediaId = call.argument<String>("id")?.toLongOrNull()
        if (mediaId == null) {
            result.error("bad_args", "id must be a numeric media id", null)
            return
        }
        try {
            result.success(MediaMetadataProbe.durationOf(context.contentResolver, mediaId))
        } catch (e: Exception) {
            result.success(null)
        }
    }

    private fun insideAppStorage(file: File): Boolean {
        val roots = listOfNotNull(
            context.filesDir, context.cacheDir,
            context.getExternalFilesDir(null), context.getExternalCacheDir(),
        )
        val prefix = file.path + File.separator
        return roots.any { root ->
            runCatching { prefix.startsWith(root.canonicalFile.path + File.separator) }
                .getOrDefault(false)
        }
    }

    /** Runs [block] on the probe pool and answers on the platform thread. */
    private fun replyOnMain(
        result: MethodChannel.Result,
        block: () -> Map<String, Any?>,
    ) {
        val main = Handler(Looper.getMainLooper())
        ImageDecodeProbe.submit {
            try {
                val payload = block()
                main.post { result.success(payload) }
            } catch (e: Exception) {
                main.post { result.error("probe_failed", e.javaClass.simpleName, null) }
            }
        }
    }

    private fun permission(): String = permissionState(Build.VERSION.SDK_INT) {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * Files of the given albums: id, name, type, size, dimensions, path and
     * whether this app owns them. Returns the actual permission state too.
     */
    private fun savedMediaIndex(call: MethodCall, result: MethodChannel.Result) {
        val albums = (call.argument<List<String>>("albums") ?: emptyList())
            .map { it.trim().lowercase() }.filter { it.isNotEmpty() }.distinct()
        val permission = permission()
        val items = mutableListOf<Map<String, Any?>>()
        var error: String? = null
        if (albums.isNotEmpty()) {
            for ((type, collection) in listOf(
                "image" to MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                "video" to MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            )) {
                try {
                    items += queryCollection(context.contentResolver, collection, type, albums)
                } catch (e: SecurityException) {
                    // Android 9 and below need read permission even for own files.
                    error = "security"
                } catch (e: Exception) {
                    error = e.javaClass.simpleName
                }
            }
        }
        result.success(mapOf(
            "permission" to permission,
            "sdk" to Build.VERSION.SDK_INT,
            "items" to items,
            "error" to error,
        ))
    }

    private fun queryCollection(
        resolver: ContentResolver,
        collection: Uri,
        type: String,
        albums: List<String>,
    ): List<Map<String, Any?>> {
        val modern = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        val projection = buildList {
            add(MediaStore.MediaColumns._ID)
            add(MediaStore.MediaColumns.DISPLAY_NAME)
            add(MediaStore.MediaColumns.SIZE)
            add(MediaStore.MediaColumns.WIDTH)
            add(MediaStore.MediaColumns.HEIGHT)
            if (modern) {
                add(MediaStore.MediaColumns.RELATIVE_PATH)
                add(MediaStore.MediaColumns.OWNER_PACKAGE_NAME)
            }
        }.toTypedArray()
        val out = mutableListOf<Map<String, Any?>>()
        resolver.query(collection, projection, bucketSelection(albums.size),
            albums.toTypedArray(), null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val owner = if (modern) cursor.getString(6) else null
                out += mapOf(
                    "id" to cursor.getLong(0).toString(),
                    "title" to cursor.getString(1),
                    "size" to cursor.getLong(2),
                    "width" to cursor.getInt(3),
                    "height" to cursor.getInt(4),
                    "relativePath" to if (modern) cursor.getString(5) else null,
                    "owned" to (owner == context.packageName),
                    "type" to type,
                )
            }
        }
        return out
    }

    /** Free bytes for temp files (app cache) and for the shared album volume. */
    private fun storageInfo(result: MethodChannel.Result) {
        fun free(path: String?): Long? = try {
            path?.let { StatFs(it).availableBytes }
        } catch (_: Exception) {
            null
        }
        result.success(mapOf(
            "cacheFree" to free(context.cacheDir?.path),
            "externalFree" to free(Environment.getExternalStorageDirectory()?.path),
        ))
    }

    /** MediaStore SIZE of one image or video, or null when not visible. */
    private fun mediaSize(call: MethodCall, result: MethodChannel.Result) {
        val mediaId = call.argument<String>("id")?.toLongOrNull()
        if (mediaId == null) {
            result.error("bad_args", "id must be a numeric media id", null)
            return
        }
        val collection = if (call.argument<Boolean>("video") == true) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        try {
            val uri = ContentUris.withAppendedId(collection, mediaId)
            val size = context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.SIZE),
                null, null, null)?.use { if (it.moveToFirst()) it.getLong(0) else null }
            result.success(size)
        } catch (e: Exception) {
            result.success(null)
        }
    }

    /** MediaStore SIZE of many ids (images and videos), id -> bytes. */
    private fun mediaSizes(call: MethodCall, result: MethodChannel.Result) {
        val ids = (call.argument<List<String>>("ids") ?: emptyList())
            .mapNotNull { it.toLongOrNull() }.distinct()
        val sizes = mutableMapOf<String, Long>()
        try {
            for (chunk in ids.chunked(400)) {
                context.contentResolver.query(MediaStore.Files.getContentUri("external"),
                    arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.SIZE),
                    "${MediaStore.MediaColumns._ID} IN (" + chunk.joinToString(",") { "?" } + ")",
                    chunk.map { it.toString() }.toTypedArray(), null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        sizes[cursor.getLong(0).toString()] = cursor.getLong(1)
                    }
                }
            }
        } catch (_: Exception) {
            // Sizes are optional backup data; missing ones are omitted.
        }
        result.success(sizes)
    }

    private fun readMediaHeader(call: MethodCall, result: MethodChannel.Result) {
        val mediaId = call.argument<String>("id")?.toLongOrNull()
        if (mediaId == null) {
            result.error("bad_args", "id must be a numeric media id", null)
            return
        }
        val mimeType = call.argument<String>("mimeType")
        try {
            val isVideo = mimeType?.startsWith("video/") == true ||
                mimeType?.contains("mp4") == true ||
                mimeType?.contains("quicktime") == true
            val collection = if (isVideo) {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
            val uri = ContentUris.withAppendedId(collection, mediaId)
            result.success(MediaHeaderReader.readHeader(context.contentResolver, uri, mimeType))
        } catch (e: Exception) {
            result.error("read_failed", e.message, null)
        }
    }

    private fun queryMediaAlbum(call: MethodCall, result: MethodChannel.Result) {
        val mediaId = call.argument<String>("id")?.toLongOrNull()
        if (mediaId == null) {
            result.error("bad_args", "id must be a numeric media id", null)
            return
        }
        try {
            val uri = ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"), mediaId)
            result.success(MediaHeaderReader.queryAlbum(context.contentResolver, uri))
        } catch (e: Exception) {
            result.error("query_failed", e.message, null)
        }
    }

    private fun scanFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val mimeType = call.argument<String>("mimeType")
        if (path == null) {
            result.error("bad_args", "path required", null)
            return
        }
        val main = Handler(Looper.getMainLooper())
        try {
            MediaScannerConnection.scanFile(context, arrayOf(path),
                if (mimeType != null) arrayOf(mimeType) else null) { _, uri ->
                main.post { result.success(uri?.toString()) }
            }
        } catch (e: Exception) {
            result.error("scan_failed", e.message, null)
        }
    }
}
