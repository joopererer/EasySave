package com.james.easysave

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Store signed media unchanged, beside its full-filename XMP sidecar.
 * Downloads accepts both real MIME types under scoped storage. No broad grant.
 */
object ProvenancePairWriter {
    fun sidecarName(mediaName: String): String {
        require(mediaName.isNotBlank() && mediaName !in setOf(".", "..") &&
            mediaName.none { it == '/' || it == '\\' || it == '\u0000' })
        return "$mediaName.xmp"
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "easysave/provenance_pair").setMethodCallHandler { call, result ->
            if (call.method !in setOf("savePair", "readSidecar", "queryFixedMedia")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            Thread {
                try {
                    val value = if (call.method == "queryFixedMedia") {
                        queryFixedMedia(context)
                    } else if (call.method == "readSidecar") {
                        read(context, call.argument<String>("mediaId")!!)
                    } else {
                        val path = call.argument<String>("path")!!
                        val source = File(path).canonicalFile
                        require(source.path.startsWith(File(context.applicationInfo.dataDir).canonicalPath + File.separator))
                        save(context, source, call.argument<String>("mime")!!)
                    }
                    Handler(Looper.getMainLooper()).post { result.success(value) }
                } catch (_: Exception) {
                    Handler(Looper.getMainLooper()).post {
                        result.error("provenance_pair", "来源信息边车保存或读取失败", null)
                    }
                }
            }.start()
        }
    }

    private fun save(context: Context, source: File, mime: String): Map<String, String> {
        val sidecar = File(source.path + ".xmp")
        require(source.isFile && sidecar.isFile && sidecar.length() in 1..1048576)
        require(mime in setOf("image/jpeg", "image/png", "image/webp", "video/mp4"))
        if (Build.VERSION.SDK_INT < 29) return saveLegacy(context, source, sidecar, mime)
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val relative = C2paStoragePolicy.RELATIVE_PATH
        val inserted = mutableListOf<Uri>()
        try {
            fun insert(name: String, type: String, file: File): Uri {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, type)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = checkNotNull(resolver.insert(collection, values))
                inserted.add(uri)
                checkNotNull(resolver.openOutputStream(uri, "w")).use { out ->
                    file.inputStream().use { it.copyTo(out) }
                }
                // Confirm the stored bytes, including C2PA credentials, are intact.
                val expected = java.security.MessageDigest.getInstance("SHA-256")
                val actual = java.security.MessageDigest.getInstance("SHA-256")
                fun digest(input: java.io.InputStream, md: java.security.MessageDigest) {
                    input.use { stream ->
                        val buffer = ByteArray(65536)
                        while (true) { val n = stream.read(buffer); if (n < 0) break; md.update(buffer, 0, n) }
                    }
                }
                digest(file.inputStream(), expected)
                digest(checkNotNull(resolver.openInputStream(uri)), actual)
                check(expected.digest().contentEquals(actual.digest()))
                return uri
            }
            // Unique pair name prevents a pre-existing .xmp from being overwritten
            // or the provider renaming it independently from its media partner.
            val base = source.nameWithoutExtension
            val name = "${base}_${java.util.UUID.randomUUID()}.${source.extension}"
            val media = insert(name, mime, source)
            val storedName = resolver.query(media, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)!!.use {
                check(it.moveToFirst()); it.getString(0)
            }
            val xmp = insert(sidecarName(storedName), "application/rdf+xml", sidecar)
            resolver.query(xmp, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)!!.use {
                check(it.moveToFirst() && it.getString(0) == sidecarName(storedName))
            }
            for (uri in inserted) resolver.update(uri, ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }, null, null)
            return mapOf("mediaId" to media.lastPathSegment!!, "title" to storedName, "relativePath" to relative)
        } catch (e: Exception) {
            for (uri in inserted) runCatching { resolver.delete(uri, null, null) }
            throw e
        }
    }

    @Suppress("DEPRECATION")
    private fun saveLegacy(context: Context, source: File, sidecar: File, mime: String): Map<String, String> {
        val directory = fixedDirectory()
        check(directory.isDirectory || directory.mkdirs())
        val media = File(directory, "${source.nameWithoutExtension}_${java.util.UUID.randomUUID()}.${source.extension}")
        val xmp = File(directory, sidecarName(media.name))
        try {
            source.copyTo(media)
            sidecar.copyTo(xmp)
            check(media.length() == source.length() && xmp.readBytes().contentEquals(sidecar.readBytes()))
            val latch = java.util.concurrent.CountDownLatch(1)
            var saved: Uri? = null
            android.media.MediaScannerConnection.scanFile(context, arrayOf(media.path), arrayOf(mime)) { _, uri ->
                saved = uri
                latch.countDown()
            }
            check(latch.await(30, java.util.concurrent.TimeUnit.SECONDS))
            return mapOf("mediaId" to checkNotNull(saved).lastPathSegment!!,
                "title" to media.name, "relativePath" to C2paStoragePolicy.RELATIVE_PATH)
        } catch (e: Exception) {
            media.delete(); xmp.delete()
            throw e
        }
    }

    @Suppress("DEPRECATION")
    private fun fixedDirectory(): File = File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
        C2paStoragePolicy.DIRECTORY_NAME)

    /** RELATIVE_PATH equality deliberately ignores bucket names and used albums. */
    private fun queryFixedMedia(context: Context): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        val modern = Build.VERSION.SDK_INT >= 29
        val projection = arrayOf("_id", "_display_name", "mime_type", "media_type", "width", "height",
            if (modern) "relative_path" else "_data")
        val selection = if (modern) C2paStoragePolicy.MEDIA_SELECTION else "_data LIKE ? AND media_type IN (1, 3)"
        val args = arrayOf(if (modern) C2paStoragePolicy.RELATIVE_PATH else fixedDirectory().path + "/%")
        context.contentResolver.query(MediaStore.Files.getContentUri("external"), projection,
            selection, args, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (!modern && File(cursor.getString(6)).parentFile?.canonicalPath != fixedDirectory().canonicalPath) continue
                val mime = cursor.getString(2)
                if (!C2paStoragePolicy.isFixedMedia(C2paStoragePolicy.RELATIVE_PATH, mime)) continue
                result.add(mapOf("id" to cursor.getString(0), "title" to cursor.getString(1),
                    "mimeType" to mime, "typeInt" to if (cursor.getInt(3) == 1) 1 else 2,
                    "width" to cursor.getInt(4), "height" to cursor.getInt(5),
                    "relativePath" to C2paStoragePolicy.RELATIVE_PATH))
            }
        }
        return result
    }

    /** Capture sidecar URIs before the OS removes the media row. */
    fun sidecarsFor(context: Context, ids: List<String>): List<Uri> {
        if (Build.VERSION.SDK_INT < 29) return emptyList()
        val resolver = context.contentResolver
        val result = mutableListOf<Uri>()
        for (id in ids.distinct()) {
            val name = resolver.query(MediaStore.Files.getContentUri("external"), arrayOf("_display_name", "relative_path"),
                "_id = ?", arrayOf(id), null)?.use {
                if (it.moveToFirst() && it.getString(1) == C2paStoragePolicy.RELATIVE_PATH) it.getString(0) else null
            } ?: continue
            resolver.query(MediaStore.Downloads.EXTERNAL_CONTENT_URI, arrayOf("_id"),
                "_display_name = ? AND relative_path = ?", arrayOf(sidecarName(name), C2paStoragePolicy.RELATIVE_PATH), null)?.use {
                while (it.moveToNext()) result.add(Uri.withAppendedPath(MediaStore.Downloads.EXTERNAL_CONTENT_URI, it.getString(0)))
            }
        }
        return result.distinct()
    }

    fun deleteSidecars(context: Context, sidecars: List<Uri>) {
        for (uri in sidecars) {
            context.contentResolver.delete(uri, null, null)
            context.contentResolver.query(uri, arrayOf("_id"), null, null, null)?.use {
                check(!it.moveToFirst()) { "Sidecar was not deleted" }
            }
        }
    }

    private fun read(context: Context, id: String): String? {
        val resolver = context.contentResolver
        val files = MediaStore.Files.getContentUri("external")
        if (Build.VERSION.SDK_INT < 29) {
            @Suppress("DEPRECATION")
            val path = resolver.query(files, arrayOf(MediaStore.MediaColumns.DATA), "_id = ?", arrayOf(id), null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: return null
            val sidecar = File(path + ".xmp")
            return if (sidecar.isFile && sidecar.length() <= 1048576) sidecar.readText() else null
        }
        val identity = resolver.query(files,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.RELATIVE_PATH),
            "_id = ?", arrayOf(id), null)?.use {
            if (it.moveToFirst()) Pair(it.getString(0), it.getString(1)) else null
        } ?: return null
        val uri = resolver.query(MediaStore.Downloads.EXTERNAL_CONTENT_URI, arrayOf("_id"),
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
            arrayOf(sidecarName(identity.first), identity.second), null)?.use {
            if (it.moveToFirst()) Uri.withAppendedPath(MediaStore.Downloads.EXTERNAL_CONTENT_URI, it.getString(0)) else null
        } ?: return null
        return resolver.openInputStream(uri)?.use {
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (output.size() <= 1048576) {
                val n = it.read(buffer)
                if (n < 0) break
                output.write(buffer, 0, n)
            }
            val bytes = output.toByteArray()
            check(bytes.size <= 1048576)
            bytes.toString(Charsets.UTF_8)
        }
    }
}
