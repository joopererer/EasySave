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

/**
 * Pure decision for "does the backup folder still work?".
 *
 * A folder may only be declared lost when the answer is certain: a probe that
 * threw (e.g. the channel was not attached yet, the volume was busy) is
 * [State.UNKNOWN] and the caller must keep the current setting.
 */
object SafFolderGrant {
    enum class State { OK, LOST, UNKNOWN }

    data class Decision(val state: State, val reason: String)

    fun decide(
        uriValid: Boolean,
        persistedGrants: Int,
        matched: Boolean,
        documentExists: Boolean,
        isDirectory: Boolean,
        writable: Boolean,
        probeFailed: Boolean,
    ): Decision = when {
        !uriValid -> Decision(State.LOST, "invalid_uri")
        probeFailed -> Decision(State.UNKNOWN, "probe_failed")
        !matched -> Decision(State.LOST, "grant_missing")
        !documentExists -> Decision(State.LOST, "directory_missing")
        !isDirectory -> Decision(State.LOST, "not_a_directory")
        !writable -> Decision(State.LOST, "not_writable")
        else -> Decision(State.OK, "ok")
    }
}

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
            "checkFolderGrant" -> {
                val treeUri = call.argument<String>("treeUri")
                if (treeUri != null) {
                    checkFolderGrant(treeUri, result)
                } else {
                    result.success(mapOf(
                        "state" to "lost",
                        "reason" to "no_uri",
                        "grants" to 0,
                        "matched" to false,
                        "authority" to "",
                    ))
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
        // A probe that could not answer keeps the folder usable: only a
        // confirmed loss may pause the automatic backup.
        result.success(probeFolder(treeUriString).state != SafFolderGrant.State.LOST)
    }

    /**
     * Detailed folder probe for the backup settings: reports *why* a folder is
     * unusable so the app can tell "the grant is really gone" from "the probe
     * could not answer yet" (and never silently switch auto backup off).
     */
    private fun checkFolderGrant(treeUriString: String, result: MethodChannel.Result) {
        val probe = probeFolder(treeUriString)
        result.success(mapOf(
            "state" to probe.state.name.lowercase(),
            "reason" to probe.reason,
            "grants" to probe.grants,
            "matched" to probe.matched,
            "exists" to probe.exists,
            "writable" to probe.writable,
            // Authority type only; the app never logs the full tree URI.
            "authority" to probe.authority,
        ))
    }

    private class FolderProbe(
        val state: SafFolderGrant.State,
        val reason: String,
        val grants: Int,
        val matched: Boolean,
        val exists: Boolean,
        val writable: Boolean,
        val authority: String,
    )

    private fun probeFolder(treeUriString: String): FolderProbe {
        var grants = 0
        var matched = false
        var exists = false
        var directory = false
        var writable = false
        var probeFailed = false
        val uri = try {
            Uri.parse(treeUriString)
        } catch (e: Exception) {
            null
        }
        if (uri != null) {
            try {
                val persisted = context.contentResolver.persistedUriPermissions
                grants = persisted.size
                matched = persisted.any {
                    it.uri == uri && (it.isWritePermission || it.isReadPermission)
                }
            } catch (e: Exception) {
                probeFailed = true
                NativeLog.w("EasySaveSAF", "folder grant probe failed type=${e.javaClass.simpleName}")
            }
            if (!probeFailed) {
                try {
                    val treeDoc = DocumentFile.fromTreeUri(context, uri)
                    exists = treeDoc?.exists() == true
                    directory = treeDoc?.isDirectory == true
                    writable = treeDoc?.canWrite() == true
                } catch (e: Exception) {
                    probeFailed = true
                    NativeLog.w("EasySaveSAF", "folder document probe failed type=${e.javaClass.simpleName}")
                }
            }
        }
        val decision = SafFolderGrant.decide(
            uriValid = uri != null,
            persistedGrants = grants,
            matched = matched,
            documentExists = exists,
            isDirectory = directory,
            writable = writable,
            probeFailed = probeFailed,
        )
        return FolderProbe(
            decision.state,
            decision.reason,
            grants,
            matched,
            exists,
            writable,
            uri?.authority ?: "",
        )
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
