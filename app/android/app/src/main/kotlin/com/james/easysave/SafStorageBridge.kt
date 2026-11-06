package com.james.easysave

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.IOException

/** Storage-only SAF operations shared by foreground and background engines. */
class SafStorageBridge(private val context: Context) {
    companion object {
        fun register(context: Context, messenger: BinaryMessenger) {
            val storage = SafStorageBridge(context.applicationContext)
            MethodChannel(messenger, "easysave/saf", StandardMethodCodec.INSTANCE,
                messenger.makeBackgroundTaskQueue()).setMethodCallHandler { call, result ->
                if (!storage.handle(call, result)) {
                    result.error("FOREGROUND_REQUIRED", "Open the App to choose a folder", null)
                }
            }
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "checkDirectoryAccess" -> {
                val treeUri = call.argument<String>("treeUri")
                if (treeUri != null) {
                    checkDirectoryAccess(treeUri, result)
                } else {
                    result.success(false)
                }
            }
            "writeBackupToDirectory" -> {
                val treeUri = call.argument<String>("treeUri")
                val fileName = call.argument<String>("fileName")
                val content = call.argument<String>("content")
                if (treeUri != null && fileName != null && content != null) {
                    writeBackupToDirectory(treeUri, fileName, content, result)
                } else {
                    result.error("INVALID_ARGS", "Missing required arguments", null)
                }
            }
            "readDocumentContent" -> {
                val uri = call.argument<String>("uri")
                if (uri != null) {
                    readDocumentContent(uri, result)
                } else {
                    result.error("INVALID_ARGS", "Missing URI argument", null)
                }
            }
            "listBackupDirectory" -> {
                val treeUri = call.argument<String>("treeUri")
                if (treeUri != null) {
                    listBackupDirectory(treeUri, result)
                } else {
                    result.error("INVALID_ARGS", "Missing treeUri argument", null)
                }
            }
            "deleteDocuments" -> {
                val uris = call.argument<List<String>>("uris")
                if (uris != null) {
                    deleteDocuments(uris, result)
                } else {
                    result.error("INVALID_ARGS", "Missing uris argument", null)
                }
            }
            "getDirectoryDisplayName" -> {
                val treeUri = call.argument<String>("treeUri")
                if (treeUri != null) {
                    getDirectoryDisplayName(treeUri, result)
                } else {
                    result.success(null)
                }
            }
            else -> return false
        }
        return true
    }

    private fun checkDirectoryAccess(treeUriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(treeUriString)
            // 1. persistedUriPermissions 中仍包含该 URI 且可写
            val hasPersistedWrite = context.contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isWritePermission
            }
            if (!hasPersistedWrite) {
                result.success(false)
                return
            }
            // 2. DocumentFile 存在; 3. 是目录; 4. canWrite
            val treeDoc = DocumentFile.fromTreeUri(context, uri)
            val isValid = treeDoc != null &&
                    treeDoc.exists() &&
                    treeDoc.isDirectory &&
                    treeDoc.canWrite()
            result.success(isValid)
        } catch (e: Exception) {
            NativeLog.w("EasySaveSAF", "storage error type=${e.javaClass.simpleName}")
            result.success(false)
        }
    }

    private fun writeBackupToDirectory(
        treeUriString: String,
        fileName: String,
        content: String,
        result: MethodChannel.Result
    ) {
        try {
            val uri = Uri.parse(treeUriString)
            val treeDoc = DocumentFile.fromTreeUri(context, uri)
            if (treeDoc == null || !treeDoc.exists() || !treeDoc.isDirectory) {
                NativeLog.w("EasySaveSAF", "storage operation unavailable")
                result.error("DIRECTORY_NOT_FOUND", "Directory does not exist", null)
                return
            }

            if (!treeDoc.canWrite()) {
                NativeLog.w("EasySaveSAF", "storage operation unavailable")
                result.error("PERMISSION_LOST", "Permission lost for directory", null)
                return
            }

            // Overwrite existing file with same name if present, avoiding system auto-renaming (e.g. xxx (1).json)
            val existingFile = treeDoc.findFile(fileName)
            val targetFile = if (existingFile != null && existingFile.isFile) {
                existingFile
            } else {
                treeDoc.createFile("application/json", fileName)
            }
            if (targetFile == null) {
                NativeLog.w("EasySaveSAF", "storage operation unavailable")
                result.error("IO_ERROR", "Failed to create backup document file", null)
                return
            }

            // Always open with "wt" mode to truncate and overwrite cleanly
            val outputStream = context.contentResolver.openOutputStream(targetFile.uri, "wt")
                ?: throw IOException("Unable to open output stream for ${targetFile.uri}")

            outputStream.use { os ->
                os.write(content.toByteArray(Charsets.UTF_8))
                os.flush()
            }

            result.success(targetFile.uri.toString())
        } catch (e: SecurityException) {
            NativeLog.w("EasySaveSAF", "storage error type=${e.javaClass.simpleName}")
            result.error("PERMISSION_LOST", "Folder permission unavailable", null)
        } catch (e: IOException) {
            NativeLog.w("EasySaveSAF", "storage error type=${e.javaClass.simpleName}")
            val msg = e.message ?: ""
            if (msg.contains("ENOSPC", ignoreCase = true) || msg.contains("No space left", ignoreCase = true)) {
                result.error("STORAGE_FULL", "Storage device is full", null)
            } else {
                result.error("IO_ERROR", "Backup storage operation failed", null)
            }
        } catch (e: Exception) {
            NativeLog.w("EasySaveSAF", "storage error type=${e.javaClass.simpleName}")
            result.error("IO_ERROR", "Backup storage operation failed", null)
        }
    }

    private fun listBackupDirectory(treeUriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(treeUriString)
            val treeDoc = DocumentFile.fromTreeUri(context, uri)
            if (treeDoc == null || !treeDoc.exists() || !treeDoc.isDirectory) {
                result.success(emptyList<Map<String, String>>())
                return
            }
            val files = treeDoc.listFiles()
            val list = mutableListOf<Map<String, String>>()
            for (file in files) {
                val name = file.name ?: continue
                list.add(mapOf(
                    "name" to name,
                    "uri" to file.uri.toString()
                ))
            }
            result.success(list)
        } catch (e: Exception) {
            NativeLog.w("EasySaveSAF", "storage error type=${e.javaClass.simpleName}")
            result.success(emptyList<Map<String, String>>())
        }
    }

    private fun deleteDocuments(uris: List<String>, result: MethodChannel.Result) {
        val results = mutableMapOf<String, Boolean>()
        for (uriStr in uris) {
            var deleted = false
            try {
                val uri = Uri.parse(uriStr)
                deleted = DocumentsContract.deleteDocument(context.contentResolver, uri)
            } catch (e: Exception) {
                try {
                    val doc = DocumentFile.fromSingleUri(context, Uri.parse(uriStr))
                    deleted = doc?.delete() ?: false
                } catch (e2: Exception) {
                    NativeLog.w("EasySaveSAF", "storage error type=${e2.javaClass.simpleName}")
                }
            }
            results[uriStr] = deleted
        }
        result.success(results)
    }

    private fun readDocumentContent(uriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            val inputStream = context.contentResolver.openInputStream(uri)
                ?: throw IOException("Unable to open input stream for $uriString")
            val content = inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            result.success(content)
        } catch (e: SecurityException) {
            NativeLog.w("EasySaveSAF", "storage error type=${e.javaClass.simpleName}")
            result.error("PERMISSION_LOST", "Folder permission unavailable", null)
        } catch (e: IOException) {
            NativeLog.w("EasySaveSAF", "storage error type=${e.javaClass.simpleName}")
            result.error("IO_ERROR", "Backup storage operation failed", null)
        } catch (e: Exception) {
            NativeLog.w("EasySaveSAF", "storage error type=${e.javaClass.simpleName}")
            result.error("IO_ERROR", "Backup storage operation failed", null)
        }
    }

    private fun getDirectoryDisplayName(treeUriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(treeUriString)
            val treeDoc = DocumentFile.fromTreeUri(context, uri)
            result.success(treeDoc?.name)
        } catch (e: Exception) {
            NativeLog.w("EasySaveSAF", "storage error type=${e.javaClass.simpleName}")
            result.success(null)
        }
    }
}
