package com.james.easysave

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

object PublicMediaWriter {
    val lock = Any()
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
        require(mime in setOf("image/jpeg", "image/png", "image/webp", "video/mp4"))
        val relative = ExportNames.albumPath(album)
        available(context, relative, name)
        if (Build.VERSION.SDK_INT < 29) return@synchronized legacy(context, source, mime, relative, name)
        val resolver = context.contentResolver
        val collection = if (mime.startsWith("image/")) MediaStore.Images.Media.EXTERNAL_CONTENT_URI else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val values = ContentValues().apply {
            put("_display_name", name); put("mime_type", mime); put("relative_path", relative); put("is_pending", 1)
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
            mapOf("mediaId" to uri.lastPathSegment!!, "title" to name, "relativePath" to relative)
        } catch (e: Exception) {
            try { resolver.delete(uri, null, null) } catch (cleanup: Exception) { throw IllegalStateException("Save and cleanup failed: ${cleanup.javaClass.simpleName}", e) }
            throw e
        }
    }
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
