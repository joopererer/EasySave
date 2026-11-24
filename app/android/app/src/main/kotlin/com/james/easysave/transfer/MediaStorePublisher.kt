package com.james.easysave.transfer

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Looper
import android.provider.MediaStore
import com.james.easysave.ExportNames
import com.james.easysave.MediaImportPolicy
import com.james.easysave.MediaMetadataProbe
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

class MediaStorePublisher(private val context: Context) : MediaPublisher {

    override fun exists(relativePath: String, displayName: String): Boolean {
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = context.contentResolver
            return resolver.query(
                MediaStore.Files.getContentUri("external"),
                arrayOf("_id"),
                "relative_path = ? AND _display_name IN (?, ?)",
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
        ExportNames.requireClean(displayName)
        MediaImportPolicy.requireAllowed(mime)
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
        val video = !mime.startsWith("image/")
        val collection = if (mime.startsWith("image/")) {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        val meta = if (video) MediaMetadataProbe.probeFile(sourceFile) else null
        val values = ContentValues().apply {
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
        val uri = checkNotNull(resolver.insert(collection, values)) { "MediaStore insert returned null" }
        val mediaId = uri.lastPathSegment ?: uri.toString()
        return PublishedHandle(
            mediaId = mediaId,
            uriString = uri.toString(),
            displayName = displayName,
            relativePath = relativePath,
        )
    }

    override fun copyAndPublish(
        handle: PublishedHandle,
        sourceFile: File,
        mime: String,
    ): PublishedMedia {
        val isMain = Looper.myLooper() == Looper.getMainLooper()
        val md = MessageDigest.getInstance("MD5")
        val buffer = ByteArray(65536)
        var copiedBytes = 0L

        if (Build.VERSION.SDK_INT < 29) {
            @Suppress("DEPRECATION")
            val parent = File(Environment.getExternalStorageDirectory(), handle.relativePath)
            check(parent.isDirectory || parent.mkdirs())
            val target = File(parent, handle.displayName)
            check(target.createNewFile())
            try {
                sourceFile.inputStream().use { input ->
                    target.outputStream().use { output ->
                        while (true) {
                            val n = input.read(buffer)
                            if (n <= 0) break
                            md.update(buffer, 0, n)
                            output.write(buffer, 0, n)
                            copiedBytes += n
                        }
                        output.flush()
                    }
                }
                val latch = java.util.concurrent.CountDownLatch(1)
                var scanUri: Uri? = null
                MediaScannerConnection.scanFile(context, arrayOf(target.path), arrayOf(mime)) { _, uri ->
                    scanUri = uri
                    latch.countDown()
                }
                check(latch.await(30, java.util.concurrent.TimeUnit.SECONDS))
                val mediaId = scanUri?.lastPathSegment ?: handle.displayName
                val md5Hex = md.digest().joinToString("") { "%02x".format(it) }
                return PublishedMedia(
                    mediaId = mediaId,
                    title = handle.displayName,
                    relativePath = handle.relativePath,
                    md5 = md5Hex,
                    size = copiedBytes,
                    thread = if (isMain) "main" else "bg",
                )
            } catch (e: Exception) {
                target.delete()
                throw e
            }
        }

        val resolver = context.contentResolver
        val uri = Uri.parse(handle.uriString)
        try {
            checkNotNull(resolver.openOutputStream(uri, "w")).use { out ->
                sourceFile.inputStream().use { input ->
                    while (true) {
                        val n = input.read(buffer)
                        if (n <= 0) break
                        md.update(buffer, 0, n)
                        out.write(buffer, 0, n)
                        copiedBytes += n
                    }
                    out.flush()
                }
            }

            resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
                check(it.moveToFirst() && it.getString(0) == handle.displayName) { "Provider changed final filename" }
            }

            val updateCount = resolver.update(uri, ContentValues().apply { put("is_pending", 0) }, null, null)
            check(updateCount == 1) { "Failed to unmark is_pending" }

            val md5Hex = md.digest().joinToString("") { "%02x".format(it) }
            val video = !mime.startsWith("image/")
            val duration = if (video) {
                handle.mediaId.toLongOrNull()?.let { MediaMetadataProbe.durationOf(resolver, it) }
            } else null

            return PublishedMedia(
                mediaId = handle.mediaId,
                title = handle.displayName,
                relativePath = handle.relativePath,
                md5 = md5Hex,
                size = copiedBytes,
                thread = if (isMain) "main" else "bg",
                duration = duration,
            )
        } catch (e: Exception) {
            try { resolver.delete(uri, null, null) } catch (_: Exception) {}
            throw e
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

