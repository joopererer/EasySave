package com.james.easysave

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

object LegacyNameRepair {
    fun run(context: Context, albums: List<String>): List<Map<String, Any?>> = synchronized(PublicMediaWriter.lock) {
        val result = mutableListOf<Map<String, Any?>>()
        val scopes = ExportNames.repairScopes(albums)
        for (relative in scopes) {
            try {
                val candidates = linkedMapOf<String, String?>()
                if (Build.VERSION.SDK_INT >= 29) {
                    try {
                    context.contentResolver.query(MediaStore.Files.getContentUri("external"), arrayOf("_id", "_display_name"),
                        "relative_path = ? AND is_pending = 0", arrayOf(relative), null)?.use { c ->
                        while (c.moveToNext()) { val name = c.getString(1); if (ExportNames.legacyTarget(name) != null) candidates[name] = c.getString(0) }
                    }
                    } catch (e: Exception) {
                        result.add(mapOf("file" to "<directory>", "path" to relative, "status" to "visibility_error", "errorClass" to e.javaClass.simpleName))
                    }
                }
                @Suppress("DEPRECATION")
                val directory = File(Environment.getExternalStorageDirectory(), relative)
                directory.listFiles()?.filter { it.isFile && ExportNames.legacyTarget(it.name) != null }?.forEach { candidates.putIfAbsent(it.name, null) }
                val tree = if (relative == C2paStoragePolicy.RELATIVE_PATH) FixedRebuildAccess.tree(context) else null
                tree?.listFiles()?.filter { it.isFile }?.forEach { doc ->
                    doc.name?.let { if (ExportNames.legacyTarget(it) != null) candidates.putIfAbsent(it, null) }
                }
                fun lookup(name: String): Uri? {
                    require(FixedRebuildAccess.validName(name))
                    if (tree != null) return tree.findFile(name)?.uri
                    if (Build.VERSION.SDK_INT >= 29) {
                        context.contentResolver.query(MediaStore.Files.getContentUri("external"), arrayOf("_id"),
                            "relative_path = ? AND _display_name = ?", arrayOf(relative, name), null)?.use { c ->
                            if (c.moveToFirst()) return Uri.withAppendedPath(MediaStore.Files.getContentUri("external"), c.getString(0))
                        }
                    }
                    val file = File(directory, name)
                    return if (file.isFile) Uri.fromFile(file) else null
                }
                fun rename(from: String, to: String): Boolean {
                    if (lookup(to) != null) return false
                    if (tree != null) {
                        val doc = tree.findFile(from) ?: return false
                        if (!doc.renameTo(to)) return false
                        if (doc.name != to) { check(doc.renameTo(from)); return false }
                        return true
                    }
                    val uri = lookup(from) ?: return false
                    if (uri.scheme == "file") return File(uri.path!!).renameTo(File(directory, to))
                    check(context.contentResolver.update(uri, ContentValues().apply { put("_display_name", to) }, null, null) == 1)
                    val actual = context.contentResolver.query(uri, arrayOf("_display_name"), null, null, null)!!.use { check(it.moveToFirst()); it.getString(0) }
                    if (actual != to) { check(context.contentResolver.update(uri, ContentValues().apply { put("_display_name", from) }, null, null) == 1); return false }
                    return true
                }
                for ((name, id) in candidates) {
                    val repair = ExportNames.repair(name, relative == C2paStoragePolicy.RELATIVE_PATH, { lookup(it) != null }, ::rename)
                    result.add(mapOf("file" to name, "path" to relative, "target" to repair.target,
                        "status" to repair.status, "errorClass" to repair.errorClass, "mediaId" to id,
                        "isImage" to (FixedRebuildAccess.mime(name)?.startsWith("image/") == true),
                        "requiresAccess" to (relative == C2paStoragePolicy.RELATIVE_PATH && tree == null &&
                            (repair.status == "missing_sidecar" || repair.errorClass?.contains("SecurityException") == true))))
                    if (repair.status == "renamed") {
                        val names = listOf(name, repair.target!!, "$name.xmp", "${repair.target}.xmp")
                        val latch = java.util.concurrent.CountDownLatch(names.size)
                        android.media.MediaScannerConnection.scanFile(context, names.map { File(directory, it).path }.toTypedArray(), null) { _, _ -> latch.countDown() }
                        latch.await(5, java.util.concurrent.TimeUnit.SECONDS)
                    }
                }
                result.add(mapOf("file" to "<directory>", "path" to relative, "status" to "checked", "candidates" to candidates.size))
            } catch (e: Exception) {
                result.add(mapOf("file" to "<directory>", "path" to relative, "status" to "error", "errorClass" to e.javaClass.simpleName))
            }
        }
        result
    }
}
