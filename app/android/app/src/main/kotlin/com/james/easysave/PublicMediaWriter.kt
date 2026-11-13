package com.james.easysave

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

object PublicMediaWriter {
    val lock = Any()
    fun inspect(context: Context, relative: String, name: String, pair: Boolean): Map<String, String>? {
        ExportNames.requireClean(name)
        val resolver = context.contentResolver
        @Suppress("DEPRECATION")
        val legacyPath = File(Environment.getExternalStorageDirectory(), relative + name).path
        val selection = if (Build.VERSION.SDK_INT >= 29)
            "relative_path = ? AND _display_name = ?" else "_data = ?"
        val args = if (Build.VERSION.SDK_INT >= 29)
            arrayOf(relative, name) else arrayOf(legacyPath)
        val row = resolver.query(
            MediaStore.Files.getContentUri("external"),
            arrayOf("_id", "_display_name"),
            selection, args, null
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) to cursor.getString(1) else null
        } ?: return null
        val result = mutableMapOf(
            "mediaId" to row.first, "title" to row.second, "relativePath" to relative
        )
        if (pair) {
            runCatching { ProvenancePairWriter.read(context, row.first) }
                .getOrNull()?.let { result["sidecarXml"] = it }
        } else {
            val uri = Uri.withAppendedPath(MediaStore.Files.getContentUri("external"), row.first)
            val extension = name.substringAfterLast('.', "bin")
            val copy = File.createTempFile("collision-", ".$extension", context.cacheDir)
            try {
                checkNotNull(resolver.openInputStream(uri)).use { input ->
                    copy.outputStream().use { output -> input.copyTo(output) }
                }
                result["probePath"] = copy.path
            } catch (e: Exception) {
                copy.delete()
                throw e
            }
        }
        return result
    }
    fun available(context: Context, relative: String, name: String) {
        if (Build.VERSION.SDK_INT >= 29) {
            context.contentResolver.query(MediaStore.Files.getContentUri("external"), arrayOf("_id"),
                "relative_path = ? AND _display_name IN (?, ?)", arrayOf(relative, name, "$name.xmp"), null)?.use {
                check(!it.moveToFirst()) { "Target filename already exists" }
            }
        }
        @Suppress("DEPRECATION")
        val parent = File(Environment.getExternalStorageDirectory(), relative)
        check(!File(parent, name).exists() && !File(parent, "$name.xmp").exists()) { "Target filename already exists" }
        if (relative == C2paStoragePolicy.RELATIVE_PATH) FixedRebuildAccess.tree(context)?.let {
            check(it.findFile(name) == null && it.findFile("$name.xmp") == null) { "Target filename already exists" }
        }
    }
    fun save(context: Context, source: File, mime: String, album: String, name: String): Map<String, String> = synchronized(lock) {
        ExportNames.requireClean(name)
        MediaImportPolicy.requireAllowed(mime)
        val relative = ExportNames.albumPath(album)
        available(context, relative, name)
        if (Build.VERSION.SDK_INT < 29) return@synchronized legacy(context, source, mime, relative, name)
        val resolver = context.contentResolver
        val video = !mime.startsWith("image/")
        val collection = if (mime.startsWith("image/")) MediaStore.Images.Media.EXTERNAL_CONTENT_URI else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        // A video row is inserted with its real duration and pixel size: the
        // album then shows the right length even when MediaStore's own
        // extraction after publishing is skipped or late (a 0-second entry
        // that still plays when opened).
        val meta = if (video) MediaMetadataProbe.probeFile(source) else null
        val values = ContentValues().apply {
            put("_display_name", name); put("mime_type", mime); put("relative_path", relative); put("is_pending", 1)
            if (meta != null) {
                put(MediaStore.Video.Media.DURATION, meta.durationMs)
                if (meta.width > 0) put(MediaStore.Video.Media.WIDTH, meta.width)
                if (meta.height > 0) put(MediaStore.Video.Media.HEIGHT, meta.height)
            }
        }
        val uri = checkNotNull(resolver.insert(collection, values))
        try {
            checkNotNull(resolver.openOutputStream(uri, "w")).use { out -> source.inputStream().use { it.copyTo(out) } }
            resolver.query(uri, arrayOf("_display_name"), null, null, null)!!.use {
                check(it.moveToFirst() && it.getString(0) == name) { "Provider changed final filename" }
            }
            fun digest(input: java.io.InputStream): ByteArray = input.use {
                val md = java.security.MessageDigest.getInstance("SHA-256"); val buffer = ByteArray(65536)
                while (true) { val n = it.read(buffer); if (n < 0) break; md.update(buffer, 0, n) }; md.digest()
            }
            check(digest(source.inputStream()).contentEquals(digest(checkNotNull(resolver.openInputStream(uri))))) { "Saved bytes mismatch" }
            check(resolver.update(uri, ContentValues().apply { put("is_pending", 0) }, null, null) == 1)
            val mediaId = uri.lastPathSegment!!
            val duration = if (video) publishDuration(context, uri, mediaId, source, mime) else null
            buildMap {
                put("mediaId", mediaId); put("title", name); put("relativePath", relative)
                if (duration != null) put("duration", duration.toString())
            }
        } catch (e: Exception) {
            try { resolver.delete(uri, null, null) } catch (cleanup: Exception) { throw IllegalStateException("Save and cleanup failed: ${cleanup.javaClass.simpleName}", e) }
            throw e
        }
    }

    /**
     * Reads DURATION back after publishing, and rescans the file once when the
     * row still says 0 so the album and third-party galleries see the real
     * length. Returns the duration now recorded (null when not a video).
     */
    private fun publishDuration(
        context: Context,
        uri: Uri,
        mediaId: String,
        source: File,
        mime: String,
    ): Long? {
        val numericId = mediaId.toLongOrNull()
        var duration = numericId?.let { MediaMetadataProbe.durationOf(context.contentResolver, it) }
        NativeLog.i("MediaImport", "event=duration_read duration=${duration ?: -1} media=$mediaId stage=published")
        if (!MediaMetadataProbe.needsRescan(duration, true)) return duration
        val path = legacyPathOf(context, uri)
        if (path != null) {
            val latch = java.util.concurrent.CountDownLatch(1)
            runCatching {
                MediaScannerConnection.scanFile(context, arrayOf(path), arrayOf(mime)) { _, _ -> latch.countDown() }
                latch.await(10, java.util.concurrent.TimeUnit.SECONDS)
            }
        }
        // The scan runs asynchronously in MediaProvider: read the row back once
        // more and log what it says instead of assuming the scan landed.
        duration = numericId?.let { MediaMetadataProbe.durationOf(context.contentResolver, it) }
        NativeLog.i("MediaImport", "event=duration_rescan duration=${duration ?: -1} media=$mediaId path=${if (path == null) "unknown" else "album"}")
        return duration
    }

    /** Absolute path of a published row, for the scanner (API 29+). */
    private fun legacyPathOf(context: Context, uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
    }.getOrNull()
    @Suppress("DEPRECATION")
    private fun legacy(context: Context, source: File, mime: String, relative: String, name: String): Map<String, String> {
        val parent = File(Environment.getExternalStorageDirectory(), relative)
        check(parent.isDirectory || parent.mkdirs())
        val target = File(parent, name); check(target.createNewFile())
        try {
            source.inputStream().use { input -> target.outputStream().use { input.copyTo(it) } }
            val latch = java.util.concurrent.CountDownLatch(1); var uri: Uri? = null
            android.media.MediaScannerConnection.scanFile(context, arrayOf(target.path), arrayOf(mime)) { _, result -> uri = result; latch.countDown() }
            check(latch.await(30, java.util.concurrent.TimeUnit.SECONDS))
            return mapOf("mediaId" to checkNotNull(uri).lastPathSegment!!, "title" to name, "relativePath" to relative)
        } catch (e: Exception) { check(target.delete() || !target.exists()); throw e }
    }
}
