package com.james.easysave

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Store signed media unchanged, beside its full-filename XMP sidecar.
 * Downloads accepts both real MIME types under scoped storage. No broad grant.
 */
object ProvenancePairWriter {
    private class StepFailure(message: String) : Exception(message)

    private inline fun <T> step(name: String, action: () -> T): T {
        try { return action() } catch (e: Exception) {
            if (e is StepFailure) throw e
            val message = PairSavePolicy.errorMessage(name, e)
            Log.w("EasySavePair", message)
            throw StepFailure(message)
        }
    }
    fun sidecarName(mediaName: String): String {
        require(mediaName.isNotBlank() && mediaName !in setOf(".", "..") &&
            mediaName.none { it == '/' || it == '\\' || it == '\u0000' })
        return "$mediaName.xmp"
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "easysave/provenance_pair").setMethodCallHandler { call, result ->
            if (call.method !in setOf("savePair", "saveMedia", "repairLegacyNames", "readSidecar", "readSidecarDetailed", "queryFixedMedia", "deletePair", "setFixedTree", "readFixedHeader")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            Thread {
                try {
                    val value = if (call.method == "repairLegacyNames") {
                        LegacyNameRepair.run(context, call.argument<List<String>>("albums") ?: emptyList())
                    } else if (call.method == "setFixedTree") {
                        FixedRebuildAccess.grant(context, call.argument<String>("treeUri")!!); true
                    } else if (call.method == "readFixedHeader") {
                        val id = call.argument<String>("mediaId")!!
                        require(id.startsWith(FixedRebuildAccess.PREFIX))
                        val name = Uri.decode(id.removePrefix(FixedRebuildAccess.PREFIX))
                        MediaHeaderReader.readHeader(context.contentResolver, FixedRebuildAccess.mediaUri(context, name), call.argument<String>("mimeType")) ?: byteArrayOf()
                    } else if (call.method == "readSidecarDetailed") {
                        if (Build.VERSION.SDK_INT >= 29) FixedRebuildAccess.readSidecar(context,
                            call.argument<String>("mediaId")!!, call.argument<String>("filename"), call.argument<String>("relativePath"))
                        else {
                            val xml = read(context, call.argument<String>("mediaId")!!)
                            mapOf("status" to if (xml == null) "not_found" else "success", "found" to (xml != null), "stage" to "legacy-sidecar-read", "xml" to xml)
                        }
                    } else if (call.method == "deletePair") {
                        deletePair(context, call.argument<String>("mediaId")!!)
                        null
                    } else if (call.method == "queryFixedMedia") {
                        if (Build.VERSION.SDK_INT >= 29) FixedRebuildAccess.query(context) else queryFixedMedia(context)
                    } else if (call.method == "readSidecar") {
                        read(context, call.argument<String>("mediaId")!!)
                    } else {
                        val path = call.argument<String>("path")!!
                        val source = File(path).canonicalFile
                        require(source.path.startsWith(File(context.applicationInfo.dataDir).canonicalPath + File.separator))
                        if (call.method == "saveMedia") PublicMediaWriter.save(context, source, call.argument<String>("mime")!!,
                            call.argument<String>("album")!!, call.argument<String>("filename")!!)
                        else synchronized(PublicMediaWriter.lock) {
                            save(context, source, call.argument<String>("mime")!!, call.argument<String>("filename") ?: source.name)
                        }
                    }
                    Handler(Looper.getMainLooper()).post { result.success(value) }
                } catch (e: Exception) {
                    val message = if (e is StepFailure) e.message!! else PairSavePolicy.errorMessage(call.method, e)
                    if (e !is StepFailure) Log.w("EasySavePair", message)
                    Handler(Looper.getMainLooper()).post {
                        result.error("provenance_pair", message, null)
                    }
                }
            }.start()
        }
    }

    private fun deletePair(context: Context, id: String) = step("Dart校验失败成组清理") {
        require(id.all { it.isDigit() } && id.isNotEmpty())
        val resolver = context.contentResolver
        val files = MediaStore.Files.getContentUri("external")
        val media = Uri.withAppendedPath(files, id)
        if (Build.VERSION.SDK_INT >= 29) {
            resolver.query(media, arrayOf("relative_path"), null, null, null)?.use {
                check(it.moveToFirst() && it.getString(0) == C2paStoragePolicy.RELATIVE_PATH)
            } ?: error("Media row unavailable")
            val sidecars = sidecarsFor(context, listOf(id))
            val errors = (sidecars + media).mapNotNull { uri -> runCatching {
                resolver.delete(uri, null, null)
                resolver.query(uri, arrayOf("_id"), null, null, null)?.use {
                    check(!it.moveToFirst()) { "Pair row remains after cleanup" }
                }
            }.exceptionOrNull() }
            check(errors.isEmpty()) { errors.joinToString { "${it.javaClass.simpleName}: ${it.message}" } }
        } else {
            @Suppress("DEPRECATION")
            val path = resolver.query(media, arrayOf("_data"), null, null, null)?.use {
                check(it.moveToFirst()); it.getString(0)
            } ?: error("Media row unavailable")
            check(File(path).parentFile?.canonicalPath == fixedDirectory().canonicalPath)
            val errors = listOf(File(path), File(path + ".xmp")).mapNotNull { file ->
                runCatching { check(!file.exists() || file.delete()) }.exceptionOrNull()
            }
            resolver.delete(media, null, null)
            check(errors.isEmpty()) { "Pair file cleanup failed" }
        }
    }

    private fun save(context: Context, source: File, mime: String, requestedName: String): Map<String, String> {
        val sidecar = File(source.path + ".xmp")
        require(source.isFile && sidecar.isFile && sidecar.length() in 1..1048576)
        require(mime in setOf("image/jpeg", "image/png", "image/webp", "video/mp4"))
        val name = PairSavePolicy.mediaName(requestedName)
        PublicMediaWriter.available(context, C2paStoragePolicy.RELATIVE_PATH, name)
        if (Build.VERSION.SDK_INT < 29) return saveLegacy(context, source, sidecar, mime, name)
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val relative = C2paStoragePolicy.RELATIVE_PATH
        val inserted = mutableListOf<Uri>()
        try {
            fun insert(name: String, type: String, file: File, kind: String): Uri {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, type)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = step("创建$kind") {
                    checkNotNull(resolver.insert(collection, values)) { "MediaStore insert returned null" }
                }
                inserted.add(uri)
                step("写入$kind") {
                    checkNotNull(resolver.openOutputStream(uri, "w")).use { out ->
                        file.inputStream().use { it.copyTo(out) }
                    }
                }
                // Confirm the stored bytes, including C2PA credentials, are intact.
                step("回读校验$kind") {
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
                }
                return uri
            }
            // Names are deterministic. Collisions fail without replacing old files.
            val media = insert(name, mime, source, "图片")
            val storedName = step("回读校验图片文件名") { resolver.query(media, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)!!.use {
                check(it.moveToFirst()); it.getString(0)
            } }
            check(storedName == name) { "Provider changed final filename" }
            val xmp = insert(sidecarName(storedName), PairSavePolicy.SIDECAR_MIME, sidecar, "边车")
            step("回读校验边车文件名") { resolver.query(xmp, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)!!.use {
                check(it.moveToFirst() && it.getString(0) == sidecarName(storedName))
            } }
            for ((index, uri) in inserted.withIndex()) step("清除 IS_PENDING ${if (index == 0) "图片" else "边车"}") {
                check(resolver.update(uri, ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }, null, null) == 1) { "MediaStore update affected no row" }
            }
            return mapOf("mediaId" to media.lastPathSegment!!, "title" to storedName, "relativePath" to relative)
        } catch (e: Exception) {
            val failures = inserted.mapNotNull { uri ->
                runCatching { step("失败清理") {
                    resolver.delete(uri, null, null)
                    resolver.query(uri, arrayOf("_id"), null, null, null)?.use {
                        check(!it.moveToFirst()) { "MediaStore row remains after rollback" }
                    }
                } }.exceptionOrNull()?.message
            }
            if (failures.isNotEmpty()) throw StepFailure("${e.message}; ${failures.joinToString("; ")}")
            throw e
        }
    }

    @Suppress("DEPRECATION")
    private fun saveLegacy(context: Context, source: File, sidecar: File, mime: String, name: String): Map<String, String> {
        val directory = fixedDirectory()
        check(directory.isDirectory || directory.mkdirs())
        val media = File(directory, name)
        val xmp = File(directory, sidecarName(media.name))
        try {
            step("创建图片") { check(media.createNewFile()) }
            step("写入图片") { source.copyTo(media, overwrite = true) }
            step("创建边车") { check(xmp.createNewFile()) }
            step("写入边车") { sidecar.copyTo(xmp, overwrite = true) }
            step("回读校验") { check(media.readBytes().contentEquals(source.readBytes()) && xmp.readBytes().contentEquals(sidecar.readBytes())) }
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
            val failures = listOf(media, xmp).mapNotNull { file ->
                runCatching { step("失败清理") { check(!file.exists() || file.delete()) } }.exceptionOrNull()?.message
            }
            if (failures.isNotEmpty()) throw StepFailure("${e.message}; ${failures.joinToString("; ")}")
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
        val projection = arrayOf("_id", "_display_name", "mime_type", "width", "height",
            if (modern) "relative_path" else "_data")
        val selection = if (modern) C2paStoragePolicy.MEDIA_SELECTION else "_data LIKE ? AND media_type IN (1, 3)"
        val args = arrayOf(if (modern) C2paStoragePolicy.RELATIVE_PATH else fixedDirectory().path + "/%")
        // Query the collection used by savePair. A Downloads row can carry an
        // image MIME while an OEM leaves Files.media_type as MEDIA_TYPE_NONE.
        val collection = if (modern) MediaStore.Downloads.EXTERNAL_CONTENT_URI else MediaStore.Files.getContentUri("external")
        checkNotNull(context.contentResolver.query(collection, projection,
            selection, args, null)) { "Fixed Downloads query returned no cursor" }.use { cursor ->
            while (cursor.moveToNext()) {
                if (!modern && File(cursor.getString(5)).parentFile?.canonicalPath != fixedDirectory().canonicalPath) continue
                val mime = cursor.getString(2)
                val type = C2paStoragePolicy.mediaType(C2paStoragePolicy.RELATIVE_PATH, mime) ?: continue
                result.add(mapOf("id" to cursor.getString(0), "title" to cursor.getString(1),
                    "mimeType" to mime, "typeInt" to type,
                    "width" to cursor.getInt(3), "height" to cursor.getInt(4),
                    "relativePath" to C2paStoragePolicy.RELATIVE_PATH))
            }
        }
        Log.i("EasySavePair", "queryFixedMedia directory=${C2paStoragePolicy.RELATIVE_PATH} media=${result.size}")
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
