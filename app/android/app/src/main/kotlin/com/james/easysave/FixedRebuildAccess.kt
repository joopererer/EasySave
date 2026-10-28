package com.james.easysave

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.documentfile.provider.DocumentFile
import java.io.File

/** Public fixed directory only. No app-private or arbitrary tree traversal. */
object FixedRebuildAccess {
    private const val PREF = "fixed_rebuild_access"
    private const val TREE = "tree"
    const val PREFIX = "fixed:"
    fun validTreeId(id: String) = id == "primary:Download/EasySave"
    fun validName(name: String) = name.isNotBlank() && name !in setOf(".", "..") && name.none { it == '/' || it == '\\' || it == '\u0000' }
    @Suppress("DEPRECATION")
    fun directory() = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "EasySave")
    fun grant(context: Context, value: String) {
        val uri = Uri.parse(value)
        require(uri.authority == "com.android.externalstorage.documents" && validTreeId(DocumentsContract.getTreeDocumentId(uri)))
        require(context.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission })
        context.getSharedPreferences(PREF, 0).edit().putString(TREE, value).apply()
    }
    fun tree(context: Context): DocumentFile? {
        val value = context.getSharedPreferences(PREF, 0).getString(TREE, null) ?: return null
        val uri = Uri.parse(value)
        if (!context.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }) return null
        require(validTreeId(DocumentsContract.getTreeDocumentId(uri)))
        return DocumentFile.fromTreeUri(context, uri)
    }
    fun mime(name: String): String? = when (name.substringAfterLast('.', "").lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"; "png" -> "image/png"; "webp" -> "image/webp"
        "heic" -> "image/heic"; "avif" -> "image/avif"; "mp4" -> "video/mp4"; "mov" -> "video/quicktime"
        else -> null
    }
    fun mediaUri(context: Context, name: String): Uri {
        require(validName(name))
        tree(context)?.findFile(name)?.let { return it.uri }
        val file = File(directory(), name)
        if (file.isFile && file.canRead()) return Uri.fromFile(file)
        throw SecurityException("Fixed directory read authorization required")
    }
    fun query(context: Context): List<Map<String, Any?>> {
        val rows = linkedMapOf<String, Map<String, Any?>>()
        val pending = mutableSetOf<String>()
        val diagnostics = mutableListOf<Map<String, Any?>>()
        if (Build.VERSION.SDK_INT >= 29) {
            for ((label, collection) in listOf("Downloads" to MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                "Files" to MediaStore.Files.getContentUri("external"))) {
                try {
                    var visible = 0
                    checkNotNull(context.contentResolver.query(collection,
                        arrayOf("_id", "_display_name", "mime_type", "width", "height", "owner_package_name", "is_pending"),
                        "relative_path = ?", arrayOf(C2paStoragePolicy.RELATIVE_PATH), null)).use { c ->
                        while (c.moveToNext()) {
                            val name = c.getString(1)
                            if (c.getInt(6) != 0) { pending.add(name); continue }
                            val type = C2paStoragePolicy.mediaType(C2paStoragePolicy.RELATIVE_PATH, c.getString(2)) ?: continue
                            visible++
                            rows.putIfAbsent(name, mapOf("id" to c.getString(0), "title" to name, "mimeType" to c.getString(2),
                                "width" to c.getInt(3), "height" to c.getInt(4), "typeInt" to type,
                                "relativePath" to C2paStoragePolicy.RELATIVE_PATH))
                            diagnostics.add(mapOf("diagnostic" to true, "file" to name, "stage" to "query-$label",
                                "visible" to true, "owned" to (c.getString(5) == context.packageName)))
                        }
                    }
                    diagnostics.add(mapOf("diagnostic" to true, "stage" to "query-$label", "count" to visible, "visible" to (visible > 0)))
                } catch (e: Exception) {
                    diagnostics.add(mapOf("diagnostic" to true, "stage" to "query-$label", "visible" to false, "errorClass" to e.javaClass.simpleName))
                }
            }
        }
        fun add(name: String) {
            if (name in pending) return
            val mime = mime(name) ?: return
            rows.putIfAbsent(name, mapOf("id" to (PREFIX + Uri.encode(name)), "title" to name, "mimeType" to mime,
                "width" to 0, "height" to 0, "typeInt" to if (mime.startsWith("image/")) 1 else 2,
                "relativePath" to C2paStoragePolicy.RELATIVE_PATH))
        }
        try {
            val files = directory().listFiles()
            diagnostics.add(mapOf("diagnostic" to true, "stage" to "public-directory", "visible" to (files != null)))
            files?.filter { it.isFile }?.forEach { add(it.name) }
        } catch (e: Exception) {
            diagnostics.add(mapOf("diagnostic" to true, "stage" to "public-directory", "visible" to false, "errorClass" to e.javaClass.simpleName))
        }
        try {
            val folder = tree(context)
            diagnostics.add(mapOf("diagnostic" to true, "stage" to "authorized-directory", "visible" to (folder != null)))
            folder?.listFiles()?.filter { it.isFile }?.let { docs ->
                val actualNames = docs.mapNotNull { it.name }.toSet()
                rows.keys.retainAll(actualNames)
                actualNames.forEach { add(it) }
            }
        } catch (e: Exception) {
            diagnostics.add(mapOf("diagnostic" to true, "stage" to "authorized-directory", "visible" to false, "errorClass" to e.javaClass.simpleName))
        }
        return rows.values.toList() + diagnostics
    }
    fun readSidecar(context: Context, id: String, suppliedName: String?, suppliedPath: String?): Map<String, Any?> {
        var stage = "image-identity"
        var name = suppliedName
        var relative = suppliedPath
        var found = false
        try {
            if (id.startsWith(PREFIX)) { name = Uri.decode(id.removePrefix(PREFIX)); relative = C2paStoragePolicy.RELATIVE_PATH }
            if (name == null || relative == null) {
                context.contentResolver.query(MediaStore.Files.getContentUri("external"), arrayOf("_display_name", "relative_path"),
                    "_id = ?", arrayOf(id), null)?.use { c -> if (c.moveToFirst()) { name = c.getString(0); relative = c.getString(1) } }
            }
            if (name == null || relative == null) error("Media identity not visible")
            require(validName(name!!))
            val sidecarName = ProvenancePairWriter.sidecarName(name!!)
            fun read(uri: Uri): Map<String, Any?> {
                found = true; stage = "sidecar-read"
                val bytes = checkNotNull(context.contentResolver.openInputStream(uri)).use { it.readBytesLimited() }
                return mapOf("status" to "success", "found" to true, "stage" to stage, "xml" to bytes.toString(Charsets.UTF_8))
            }
            if (relative == C2paStoragePolicy.RELATIVE_PATH) {
                stage = "authorized-sidecar-lookup"
                tree(context)?.let { folder ->
                    val doc = folder.findFile(sidecarName)
                    return if (doc == null) mapOf("status" to "not_found", "found" to false, "stage" to stage) else read(doc.uri)
                }
            }
            stage = "MediaStore-sidecar-lookup"
            val uri = context.contentResolver.query(MediaStore.Downloads.EXTERNAL_CONTENT_URI, arrayOf("_id"),
                "_display_name = ? AND relative_path = ?", arrayOf(sidecarName, relative), null)?.use { c ->
                if (c.moveToFirst()) Uri.withAppendedPath(MediaStore.Downloads.EXTERNAL_CONTENT_URI, c.getString(0)) else null
            }
            if (uri != null) return read(uri)
            if (relative == C2paStoragePolicy.RELATIVE_PATH) {
                stage = "public-sidecar-lookup"
                val file = File(directory(), sidecarName)
                if (file.isFile) return read(Uri.fromFile(file))
                // A FUSE listing can hide non-media files after app data is
                // cleared. Only an authorized tree can confirm true absence.
                throw SecurityException("Authorize Download/EasySave to confirm sidecar visibility")
            }
            return mapOf("status" to "not_found", "found" to false, "stage" to stage)
        } catch (e: Exception) {
            return mapOf("status" to "error", "found" to found, "stage" to stage, "errorClass" to e.javaClass.simpleName,
                "requiresAccess" to (e is SecurityException))
        }
    }
    private fun java.io.InputStream.readBytesLimited(): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) { val n = read(buffer); if (n < 0) break; check(out.size() + n <= 1048576) { "Sidecar exceeds size limit" }; out.write(buffer, 0, n) }
        return out.toByteArray()
    }
}
