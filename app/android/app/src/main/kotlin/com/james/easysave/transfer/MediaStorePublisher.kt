package com.james.easysave.transfer

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Looper
import android.provider.MediaStore
import com.james.easysave.C2paStoragePolicy
import com.james.easysave.ExportNames
import com.james.easysave.MediaImportPolicy
import com.james.easysave.MediaMetadataProbe
import com.james.easysave.PairSavePolicy
import com.james.easysave.provenance.ChannelSeekableInput
import com.james.easysave.provenance.RafSeekableInput
import com.james.easysave.provenance.SeekableInput
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.io.OutputStream

class MediaStorePublisher(private val context: Context) : MediaPublisher {

    override fun exists(relativePath: String, displayName: String): Boolean {
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = context.contentResolver
            val selection = buildString {
                append("relative_path = ? AND _display_name IN (?, ?)")
                append(" AND (is_pending IS NULL OR is_pending = 0)")
                if (Build.VERSION.SDK_INT >= 30) {
                    append(" AND (is_trashed IS NULL OR is_trashed = 0)")
                }
            }
            return resolver.query(
                MediaStore.Files.getContentUri("external"),
                arrayOf("_id"),
                selection,
                arrayOf(relativePath, displayName, "$displayName.xmp"),
                null
            )?.use { it.moveToFirst() } ?: false
        } else {
            @Suppress("DEPRECATION")
            val parent = File(Environment.getExternalStorageDirectory(), relativePath)
            return File(parent, displayName).exists() || File(parent, "$displayName.xmp").exists()
        }
    }

    override fun insertPending(
        relativePath: String,
        displayName: String,
        mime: String,
        sourceFile: File,
    ): PublishedHandle {
        val isSidecar = displayName.endsWith(".xmp")
        if (isSidecar) {
            ExportNames.requireClean(displayName.removeSuffix(".xmp"))
            require(mime == PairSavePolicy.SIDECAR_MIME) { "Invalid sidecar MIME: $mime" }
        } else {
            ExportNames.requireClean(displayName)
            MediaImportPolicy.requireAllowed(mime)
        }
        check(!exists(relativePath, displayName)) { "Target filename already exists: $displayName" }

        if (Build.VERSION.SDK_INT < 29) {
            @Suppress("DEPRECATION")
            val legacyPath = File(Environment.getExternalStorageDirectory(), "$relativePath$displayName").path
            return PublishedHandle(
                mediaId = displayName,
                uriString = "file://$legacyPath",
                displayName = displayName,
                relativePath = relativePath,
            )
        }

        val resolver = context.contentResolver
        val isDownloads = relativePath == C2paStoragePolicy.RELATIVE_PATH
        val video = !isSidecar && !mime.startsWith("image/")
        val collection = when {
            isDownloads -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
            mime.startsWith("image/") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            else -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        val meta = if (video && sourceFile.exists()) MediaMetadataProbe.probeFile(sourceFile) else null
        val values = buildPendingValues(displayName, mime, relativePath, meta)
        val uri = checkNotNull(resolver.insert(collection, values)) { "MediaStore insert returned null" }
        val mediaId = uri.lastPathSegment ?: uri.toString()
        return PublishedHandle(
            mediaId = mediaId,
            uriString = uri.toString(),
            displayName = displayName,
            relativePath = relativePath,
        )
    }

    override fun openOutputStream(handle: PublishedHandle): OutputStream {
        if (Build.VERSION.SDK_INT < 29) {
            @Suppress("DEPRECATION")
            val parent = File(Environment.getExternalStorageDirectory(), handle.relativePath)
            check(parent.isDirectory || parent.mkdirs())
            val target = File(parent, handle.displayName)
            check(target.createNewFile() || target.exists())
            return target.outputStream()
        }
        val resolver = context.contentResolver
        val uri = Uri.parse(handle.uriString)
        return checkNotNull(resolver.openOutputStream(uri, "w")) { "Failed to open OutputStream for $uri" }
    }

    override fun publish(
        handle: PublishedHandle,
        md5: String,
        size: Long,
        mime: String,
    ): PublishedMedia {
        val isMain = Looper.myLooper() == Looper.getMainLooper()
        if (Build.VERSION.SDK_INT < 29) {
            @Suppress("DEPRECATION")
            val parent = File(Environment.getExternalStorageDirectory(), handle.relativePath)
            val target = File(parent, handle.displayName)
            val latch = java.util.concurrent.CountDownLatch(1)
            var scanUri: Uri? = null
            MediaScannerConnection.scanFile(context, arrayOf(target.path), arrayOf(mime)) { _, uri ->
                scanUri = uri
                latch.countDown()
            }
            check(latch.await(30, java.util.concurrent.TimeUnit.SECONDS))
            val mediaId = scanUri?.lastPathSegment ?: handle.displayName
            return PublishedMedia(
                mediaId = mediaId,
                title = handle.displayName,
                relativePath = handle.relativePath,
                md5 = md5,
                size = size,
                thread = if (isMain) "main" else "bg",
            )
        }

        val resolver = context.contentResolver
        val uri = Uri.parse(handle.uriString)
        val actualDisplayName = resolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
            null,
            null,
            null
        )?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: handle.displayName

        val updateCount = resolver.update(uri, ContentValues().apply { put("is_pending", 0) }, null, null)
        check(updateCount == 1) { "Failed to unmark is_pending" }

        val video = !mime.startsWith("image/")
        val duration = if (video) {
            val numericId = handle.mediaId.toLongOrNull()
            val path = legacyPathOf(uri)
            if (path != null) {
                val latch = java.util.concurrent.CountDownLatch(1)
                runCatching {
                    MediaScannerConnection.scanFile(context, arrayOf(path), arrayOf(mime)) { _, _ ->
                        latch.countDown()
                    }
                    latch.await(10, java.util.concurrent.TimeUnit.SECONDS)
                }
            }
            numericId?.let { MediaMetadataProbe.durationOf(resolver, it) }
        } else null

        return PublishedMedia(
            mediaId = handle.mediaId,
            title = actualDisplayName,
            relativePath = handle.relativePath,
            md5 = md5,
            size = size,
            thread = if (isMain) "main" else "bg",
            duration = duration,
        )
    }

    private fun legacyPathOf(uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
    }.getOrNull()

    internal fun buildPendingValues(
        displayName: String,
        mime: String,
        relativePath: String,
        meta: MediaMetadataProbe.VideoMeta?,
    ): ContentValues = ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
        put(MediaStore.MediaColumns.MIME_TYPE, mime)
        put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
        put("is_pending", 1)
        if (meta != null) {
            put(MediaStore.Video.Media.DURATION, meta.durationMs)
            if (meta.width > 0) put(MediaStore.Video.Media.WIDTH, meta.width)
            if (meta.height > 0) put(MediaStore.Video.Media.HEIGHT, meta.height)
        }
    }

    override fun deletePending(mediaId: String) {
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = context.contentResolver
            val uri = if (mediaId.startsWith("content://")) {
                Uri.parse(mediaId)
            } else {
                Uri.withAppendedPath(MediaStore.Files.getContentUri("external"), mediaId)
            }
            runCatching { resolver.delete(uri, null, null) }
        }
    }

    override fun openSeekableInput(mediaId: String): SeekableInput {
        if (Build.VERSION.SDK_INT < 29) {
            val file = File(mediaId)
            if (file.exists()) return RafSeekableInput(file)
            @Suppress("DEPRECATION")
            val inPictures = File(Environment.getExternalStorageDirectory(), "Pictures/EasySave/$mediaId")
            if (inPictures.exists()) return RafSeekableInput(inPictures)
            throw java.io.FileNotFoundException("Legacy media file not found: $mediaId")
        }
        val resolver = context.contentResolver
        val uri = if (mediaId.startsWith("content://")) {
            Uri.parse(mediaId)
        } else {
            Uri.withAppendedPath(MediaStore.Files.getContentUri("external"), mediaId)
        }
        val pfd = checkNotNull(resolver.openFileDescriptor(uri, "r")) { "Could not open FileDescriptor for: $mediaId" }
        val channel = FileInputStream(pfd.fileDescriptor).channel
        return ChannelSeekableInput(channel) { pfd.close() }
    }

    override fun openInputStream(mediaId: String): InputStream {
        if (Build.VERSION.SDK_INT < 29) {
            val file = File(mediaId)
            if (file.exists()) return file.inputStream()
            @Suppress("DEPRECATION")
            val inPictures = File(Environment.getExternalStorageDirectory(), "Pictures/EasySave/$mediaId")
            if (inPictures.exists()) return inPictures.inputStream()
            throw java.io.FileNotFoundException("Legacy media file not found: $mediaId")
        }
        val resolver = context.contentResolver
        val uri = if (mediaId.startsWith("content://")) {
            Uri.parse(mediaId)
        } else {
            Uri.withAppendedPath(MediaStore.Files.getContentUri("external"), mediaId)
        }
        return checkNotNull(resolver.openInputStream(uri)) { "Could not open InputStream for mediaId: $mediaId" }
    }
}
