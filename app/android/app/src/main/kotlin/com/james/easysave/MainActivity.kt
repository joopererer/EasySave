package com.james.easysave

import android.app.StatusBarManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import java.io.IOException
import java.util.regex.Pattern
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SEAL_CHANNEL = "easysave/seal"
        private const val SEAL_PACKAGE = "com.junkfood.seal"
        private const val MEDIA_CHANNEL = "easysave/media"
        private const val HOST_CHANNEL = "easysave/host"
        private const val TILE_CHANNEL = "easysave/tile"
        private const val BUBBLE_CHANNEL = "easysave/bubble"
        private const val SAF_CHANNEL = "easysave/saf"
        private const val DELETE_REQUEST_CODE = 50021
        private const val WRITE_REQUEST_CODE = 50022
        private const val SAF_PICK_DIRECTORY_REQUEST_CODE = 50023
        private const val SAF_PICK_FILE_REQUEST_CODE = 50024
        const val EXTRA_OPEN_URL = "easy_open_url"
    }

    /**
     * Result callback for the system's batch-delete confirmation dialog
     * (MediaStore.createDeleteRequest). Only one delete flow can be pending at
     * a time; the Dart side never issues concurrent requests.
     */
    private var pendingDeleteResult: MethodChannel.Result? = null

    /**
     * Result callback for the system's batch-write confirmation dialog
     * (MediaStore.createWriteRequest). Only one write flow can be pending at
     * a time.
     */
    private var pendingWriteResult: MethodChannel.Result? = null
    private var pendingPickDirectoryResult: MethodChannel.Result? = null
    private var pendingPickFileResult: MethodChannel.Result? = null
    private val BACKUP_FILE_PATTERN = Pattern.compile("^easysave-backup-(\\d{8}-\\d{4}(?:\\d{2})?)\\.json$")

    private var hostChannel: MethodChannel? = null
    private var receiverRegistered = false

    // Error carried by a tapped error notification, waiting for Dart to pull it
    // (cold start) or pushed to Dart immediately (warm start). Cleared once.
    private var pendingError: Map<String, String?>? = null

    // Url to open on the parse/preview page (from the bubble's "打开 EasySave").
    private var pendingOpen: String? = null

    private var bubbleChannel: MethodChannel? = null

    private val historyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            // The background engine wrote history; ask the main UI to reload.
            hostChannel?.invokeMethod("historyChanged", null)
        }
    }

    // The bubble was closed/shown (e.g. dragged to the close zone) while the
    // app is in the foreground; ask Dart to reconcile the settings toggle.
    private val bubbleReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            bubbleChannel?.invokeMethod("bubbleStateChanged", null)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleErrorIntent(intent)
        handleOpenIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleErrorIntent(intent)
        handleOpenIntent(intent)
    }

    /// Read the error extras from a tapped error notification and hand them to
    /// Dart; the extras are cleared so re-entering the app doesn't re-trigger.
    private fun handleErrorIntent(intent: Intent?) {
        val i = intent ?: return
        val code = i.getStringExtra(HostService.EXTRA_ERROR_CODE) ?: return
        val payload = mapOf(
            "url" to i.getStringExtra(HostService.EXTRA_ERROR_URL),
            "code" to code,
            "message" to i.getStringExtra(HostService.EXTRA_ERROR_MESSAGE),
        )
        i.removeExtra(HostService.EXTRA_ERROR_URL)
        i.removeExtra(HostService.EXTRA_ERROR_CODE)
        i.removeExtra(HostService.EXTRA_ERROR_MESSAGE)
        pendingError = payload
        hostChannel?.invokeMethod("openParseError", payload)
    }

    /// Read the "open this url to preview" extra (bubble → 打开 EasySave).
    private fun handleOpenIntent(intent: Intent?) {
        val i = intent ?: return
        val url = i.getStringExtra(EXTRA_OPEN_URL) ?: return
        i.removeExtra(EXTRA_OPEN_URL)
        pendingOpen = url
        hostChannel?.invokeMethod("openParse", url)
    }

    override fun onStart() {
        super.onStart()
        BubbleReconciler.reconcile(this, "main_activity")
        if (!receiverRegistered) {
            ContextCompat.registerReceiver(
                this,
                historyReceiver,
                IntentFilter(HostService.ACTION_HISTORY_CHANGED),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            ContextCompat.registerReceiver(
                this,
                bubbleReceiver,
                IntentFilter(OverlayService.ACTION_BUBBLE_STATE),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            receiverRegistered = true
        }
    }

    override fun onStop() {
        if (receiverRegistered) {
            try {
                unregisterReceiver(historyReceiver)
            } catch (_: Exception) {
            }
            try {
                unregisterReceiver(bubbleReceiver)
            } catch (_: Exception) {
            }
            receiverRegistered = false
        }
        super.onStop()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SEAL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isInstalled" -> {
                        result.success(isSealInstalled())
                    }
                    "send" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.success(false)
                        } else {
                            result.success(sendToSeal(url))
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deleteMedia" -> deleteMedia(call, result)
                    "requestWriteAccess" -> requestWriteAccess(call, result)
                    "readMediaHeader" -> readMediaHeader(call, result)
                    "queryMediaAlbum" -> queryMediaAlbum(call, result)
                    else -> result.notImplemented()
                }
            }

        // Main UI <- background HostService bridge (Dart listens on the same
        // channel name to refresh the history page; Dart can also pull a
        // pending error from a tapped error notification).
        hostChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HOST_CHANNEL)
        hostChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingError" -> result.success(pendingError)
                "clearPendingError" -> {
                    pendingError = null
                    result.success(null)
                }
                "getPendingOpen" -> result.success(pendingOpen)
                "clearPendingOpen" -> {
                    pendingOpen = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TILE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "addTile" -> addTile(result)
                    else -> result.notImplemented()
                }
            }

        bubbleChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BUBBLE_CHANNEL)
        bubbleChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(Settings.canDrawOverlays(this))
                    "requestPermission" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        } catch (_: Exception) {
                        }
                        result.success(null)
                    }
                    "start" -> {
                        if (Settings.canDrawOverlays(this)) {
                            OverlayService.start(this)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        OverlayService.stop(this)
                        result.success(null)
                    }
                    "isRunning" -> result.success(OverlayService.isRunning)
                    "updateAutoHide" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        OverlayService.updateAutoHide(enabled)
                        result.success(null)
                    }
                    "openAppSettings" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName")
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        } catch (_: Exception) {
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SAF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDirectory" -> pickDirectory(result)
                    "pickBackupFile" -> pickBackupFile(result)
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
                    "rotateBackups" -> {
                        val treeUri = call.argument<String>("treeUri")
                        if (treeUri != null) {
                            rotateBackupsInDirectory(treeUri, result)
                        } else {
                            result.error("INVALID_ARGS", "Missing treeUri argument", null)
                        }
                    }
                    "getLatestBackup" -> {
                        val treeUri = call.argument<String>("treeUri")
                        if (treeUri != null) {
                            getLatestBackup(treeUri, result)
                        } else {
                            result.error("INVALID_ARGS", "Missing treeUri argument", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Ask the system to add the Quick Settings tile (Android 13+ shows a
    /// confirmation dialog). Returns true when the tile was added or already
    /// present; false on older versions so Dart can show manual instructions.
    private fun addTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(false)
            return
        }
        try {
            val sbm = getSystemService(StatusBarManager::class.java)
            val icon = Icon.createWithResource(this, R.drawable.ic_qs_easysave)
            sbm?.requestAddTileService(
                ComponentName(this, EasySaveTileService::class.java),
                "EasySave 下载",
                icon,
                mainExecutor,
            ) { code ->
                result.success(
                    code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                        code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED
                )
            } ?: result.success(false)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            DELETE_REQUEST_CODE -> {
                pendingDeleteResult?.success(resultCode == RESULT_OK)
                pendingDeleteResult = null
            }
            WRITE_REQUEST_CODE -> {
                pendingWriteResult?.success(resultCode == RESULT_OK)
                pendingWriteResult = null
            }
            SAF_PICK_DIRECTORY_REQUEST_CODE -> {
                if (resultCode == RESULT_OK && data?.data != null) {
                    val treeUri = data.data!!
                    try {
                        val takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        contentResolver.takePersistableUriPermission(treeUri, takeFlags)
                        pendingPickDirectoryResult?.success(treeUri.toString())
                    } catch (e: Exception) {
                        Log.e("EasySaveSAF", "Failed to take persistable URI permission: ${e.message}", e)
                        pendingPickDirectoryResult?.error("PERMISSION_LOST", e.message, null)
                    }
                } else {
                    pendingPickDirectoryResult?.success(null)
                }
                pendingPickDirectoryResult = null
            }
            SAF_PICK_FILE_REQUEST_CODE -> {
                if (resultCode == RESULT_OK && data?.data != null) {
                    pendingPickFileResult?.success(data.data.toString())
                } else {
                    pendingPickFileResult?.success(null)
                }
                pendingPickFileResult = null
            }
        }
    }

    /**
     * Delete saved media through the OS-owned confirmation flow.
     *
     * Android version handling:
     *  - API >= 30 (R): `MediaStore.createDeleteRequest` batches every URI into
     *    a single system dialog; the user's answer arrives in [onActivityResult].
     *    This needs no storage permission.
     *  - API 29 (Q): the batch request API does not exist; MediaStore only
     *    offers a per-item `RecoverableSecurityException`. We do not attempt it
     *    here (a multi-file flow would raise one dialog per file and can't be
     *    neatly resolved through a single MethodChannel result), so we report
     *    `false` and Dart keeps the records, telling the user the album files
     *    were left untouched.
     *  - API < 29: legacy scoped-storage exceptions don't apply; file deletion
     *    would need write-external-storage, which we no longer request. Report
     *    `false` for the same record-only fallback.
     *
     * The media ids are the MediaStore ids that photo_manager exposes as
     * AssetEntity.id; we rebuild the content URIs from the per-item is-image
     * flag because images and videos live in different MediaStore collections.
     */
    private fun deleteMedia(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success(false)
            return
        }
        if (pendingDeleteResult != null) {
            result.error("busy", "A delete request is already in progress", null)
            return
        }

        val ids = call.argument<List<String>>("ids") ?: emptyList()
        val isImage = call.argument<List<Boolean>>("isImage") ?: emptyList()

        val uris = ArrayList<Uri>()
        for (i in ids.indices) {
            val id = ids[i].toLongOrNull() ?: continue
            val image = isImage.getOrNull(i) ?: true
            val collection = if (image) {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }
            uris.add(ContentUris.withAppendedId(collection, id))
        }
        if (uris.isEmpty()) {
            result.success(false)
            return
        }

        try {
            val pendingIntent = MediaStore.createDeleteRequest(contentResolver, uris)
            pendingDeleteResult = result
            @Suppress("DEPRECATION")
            startIntentSenderForResult(
                pendingIntent.intentSender,
                DELETE_REQUEST_CODE,
                null,
                0,
                0,
                0,
            )
        } catch (e: Exception) {
            pendingDeleteResult = null
            result.error("delete_failed", e.message, null)
        }
    }

    /**
     * Request write access for media files through the OS confirmation flow.
     *
     * On Android 11+ (API 30+), apps can only modify media files they created.
     * This method requests permission to write to existing files via
     * `MediaStore.createWriteRequest`.
     *
     * Returns true if user grants permission, false otherwise.
     */
    private fun requestWriteAccess(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            // On older versions, we have full access to external storage
            result.success(true)
            return
        }
        if (pendingWriteResult != null) {
            result.error("busy", "A write request is already in progress", null)
            return
        }

        val ids = call.argument<List<String>>("ids") ?: emptyList()
        val isImage = call.argument<List<Boolean>>("isImage") ?: emptyList()

        val uris = ArrayList<Uri>()
        for (i in ids.indices) {
            val id = ids[i].toLongOrNull() ?: continue
            val image = isImage.getOrNull(i) ?: true
            val collection = if (image) {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }
            uris.add(ContentUris.withAppendedId(collection, id))
        }
        if (uris.isEmpty()) {
            result.success(false)
            return
        }

        try {
            val pendingIntent = MediaStore.createWriteRequest(contentResolver, uris)
            pendingWriteResult = result
            @Suppress("DEPRECATION")
            startIntentSenderForResult(
                pendingIntent.intentSender,
                WRITE_REQUEST_CODE,
                null,
                0,
                0,
                0,
            )
        } catch (e: Exception) {
            pendingWriteResult = null
            result.error("write_request_failed", e.message, null)
        }
    }

    /**
     * Read only the header bytes of a media file (see [MediaHeaderReader]).
     * The result is the byte array that was read, never a byte count.
     */
    private fun readMediaHeader(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val mediaId = id?.toLongOrNull()
        if (mediaId == null) {
            result.error("bad_args", "id must be a numeric media id", null)
            return
        }
        val mimeType = call.argument<String>("mimeType")
        try {
            val uri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                mediaId,
            )
            result.success(MediaHeaderReader.readHeader(contentResolver, uri, mimeType))
        } catch (e: Exception) {
            result.error("read_failed", e.message, null)
        }
    }

    /**
     * Album (MediaStore bucket / relative path) of a media file.
     * The album name is never derived from the file name.
     */
    private fun queryMediaAlbum(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val mediaId = id?.toLongOrNull()
        if (mediaId == null) {
            result.error("bad_args", "id must be a numeric media id", null)
            return
        }
        try {
            val uri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                mediaId,
            )
            result.success(MediaHeaderReader.queryAlbum(contentResolver, uri))
        } catch (e: Exception) {
            result.error("query_failed", e.message, null)
        }
    }

    private fun isSealInstalled(): Boolean {        return try {
            packageManager.getPackageInfo(SEAL_PACKAGE, 0)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun sendToSeal(url: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, url)
                setPackage(SEAL_PACKAGE)
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        pendingPickDirectoryResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                )
            }
            startActivityForResult(intent, SAF_PICK_DIRECTORY_REQUEST_CODE)
        } catch (e: Exception) {
            Log.e("EasySaveSAF", "Failed to start ACTION_OPEN_DOCUMENT_TREE: ${e.message}", e)
            pendingPickDirectoryResult = null
            result.error("SAF_ERROR", e.message, null)
        }
    }

    private fun pickBackupFile(result: MethodChannel.Result) {
        pendingPickFileResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain", "application/octet-stream", "*/*"))
            }
            startActivityForResult(intent, SAF_PICK_FILE_REQUEST_CODE)
        } catch (e: Exception) {
            Log.e("EasySaveSAF", "Failed to start ACTION_OPEN_DOCUMENT: ${e.message}", e)
            pendingPickFileResult = null
            result.error("SAF_ERROR", e.message, null)
        }
    }

    private fun checkDirectoryAccess(treeUriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(treeUriString)
            val hasPersisted = contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isWritePermission && it.isReadPermission
            }
            val treeDoc = DocumentFile.fromTreeUri(this, uri)
            val canWrite = treeDoc != null && treeDoc.exists() && treeDoc.canWrite() && treeDoc.isDirectory
            result.success(hasPersisted && canWrite)
        } catch (e: Exception) {
            Log.w("EasySaveSAF", "checkDirectoryAccess error for $treeUriString: ${e.message}")
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
            val treeDoc = DocumentFile.fromTreeUri(this, uri)
            if (treeDoc == null || !treeDoc.exists() || !treeDoc.isDirectory) {
                Log.e("EasySaveSAF", "Directory not found: $treeUriString")
                result.error("DIRECTORY_NOT_FOUND", "Directory does not exist", null)
                return
            }

            if (!treeDoc.canWrite()) {
                Log.e("EasySaveSAF", "Permission lost for directory: $treeUriString")
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
                Log.e("EasySaveSAF", "Failed to obtain or create document file: $fileName")
                result.error("IO_ERROR", "Failed to create backup document file", null)
                return
            }

            // Always open with "wt" mode to truncate and overwrite cleanly
            val outputStream = contentResolver.openOutputStream(targetFile.uri, "wt")
                ?: throw IOException("Unable to open output stream for ${targetFile.uri}")

            outputStream.use { os ->
                os.write(content.toByteArray(Charsets.UTF_8))
                os.flush()
            }

            result.success(targetFile.uri.toString())
        } catch (e: SecurityException) {
            Log.e("EasySaveSAF", "SecurityException writing backup: ${e.message}", e)
            result.error("PERMISSION_LOST", e.message, null)
        } catch (e: IOException) {
            Log.e("EasySaveSAF", "IOException writing backup: ${e.message}", e)
            val msg = e.message ?: ""
            if (msg.contains("ENOSPC", ignoreCase = true) || msg.contains("No space left", ignoreCase = true)) {
                result.error("STORAGE_FULL", "Storage device is full", null)
            } else {
                result.error("IO_ERROR", e.message, null)
            }
        } catch (e: Exception) {
            Log.e("EasySaveSAF", "Unexpected error writing backup: ${e.message}", e)
            result.error("IO_ERROR", e.message, null)
        }
    }

    private fun rotateBackupsInDirectory(treeUriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(treeUriString)
            val treeDoc = DocumentFile.fromTreeUri(this, uri)
            if (treeDoc != null && treeDoc.exists() && treeDoc.isDirectory) {
                val deleted = rotateBackups(treeDoc)
                result.success(deleted)
            } else {
                result.success(0)
            }
        } catch (e: Exception) {
            Log.w("EasySaveSAF", "rotateBackupsInDirectory error: ${e.message}", e)
            result.success(0)
        }
    }

    private fun parseBackupTime(name: String): Long? {
        val matcher = BACKUP_FILE_PATTERN.matcher(name)
        if (!matcher.matches()) return null
        val ts = matcher.group(1) ?: return null
        return try {
            val y = ts.substring(0, 4).toInt()
            val m = ts.substring(4, 6).toInt()
            val d = ts.substring(6, 8).toInt()
            val h = ts.substring(9, 11).toInt()
            val min = ts.substring(11, 13).toInt()
            val s = if (ts.length >= 15) ts.substring(13, 15).toInt() else 0
            val cal = java.util.Calendar.getInstance()
            cal.set(y, m - 1, d, h, min, s)
            cal.set(java.util.Calendar.MILLISECOND, 0)
            cal.timeInMillis
        } catch (_: Exception) {
            null
        }
    }

    private fun rotateBackups(treeDoc: DocumentFile): Int {
        var deletedCount = 0
        try {
            val files = treeDoc.listFiles()
            val matchingBackups = mutableListOf<Pair<Long, DocumentFile>>()

            for (file in files) {
                val name = file.name ?: continue
                val timeMs = parseBackupTime(name) ?: continue
                matchingBackups.add(Pair(timeMs, file))
            }

            // Sort descending by parsed timestamp
            matchingBackups.sortByDescending { it.first }

            if (matchingBackups.size > 7) {
                for (i in 7 until matchingBackups.size) {
                    val oldFile = matchingBackups[i].second
                    try {
                        if (oldFile.delete()) {
                            deletedCount++
                        }
                    } catch (e: Exception) {
                        Log.w("EasySaveSAF", "Failed to delete rotated backup: ${oldFile.name}", e)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w("EasySaveSAF", "Rotation error: ${e.message}", e)
        }
        return deletedCount
    }

    private fun getLatestBackup(treeUriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(treeUriString)
            val treeDoc = DocumentFile.fromTreeUri(this, uri)
            if (treeDoc == null || !treeDoc.exists() || !treeDoc.isDirectory) {
                result.success(null)
                return
            }
            val files = treeDoc.listFiles()
            var latestTime = -1L
            var latestDoc: DocumentFile? = null
            for (file in files) {
                val name = file.name ?: continue
                val t = parseBackupTime(name) ?: continue
                if (t > latestTime) {
                    latestTime = t
                    latestDoc = file
                }
            }
            if (latestDoc == null) {
                result.success(null)
                return
            }
            val inputStream = contentResolver.openInputStream(latestDoc.uri)
            val text = inputStream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }
            result.success(mapOf(
                "name" to (latestDoc.name ?: ""),
                "uri" to latestDoc.uri.toString(),
                "content" to (text ?: "")
            ))
        } catch (e: Exception) {
            Log.w("EasySaveSAF", "getLatestBackup error: ${e.message}", e)
            result.success(null)
        }
    }

    private fun readDocumentContent(uriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            val inputStream = contentResolver.openInputStream(uri)
                ?: throw IOException("Unable to open input stream for $uriString")
            val content = inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            result.success(content)
        } catch (e: SecurityException) {
            Log.e("EasySaveSAF", "SecurityException reading $uriString: ${e.message}", e)
            result.error("PERMISSION_LOST", e.message, null)
        } catch (e: IOException) {
            Log.e("EasySaveSAF", "IOException reading $uriString: ${e.message}", e)
            result.error("IO_ERROR", e.message, null)
        } catch (e: Exception) {
            Log.e("EasySaveSAF", "Unexpected error reading $uriString: ${e.message}", e)
            result.error("IO_ERROR", e.message, null)
        }
    }
}
