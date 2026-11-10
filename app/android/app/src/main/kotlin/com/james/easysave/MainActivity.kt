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
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SEAL_CHANNEL = "easysave/seal"
        private const val SEAL_PACKAGE = "com.junkfood.seal"
        private const val MEDIA_CHANNEL = MediaStoreBridge.CHANNEL
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
    private var pendingDeleteSidecars: List<Uri> = emptyList()

    /**
     * Result callback for the system's batch-write confirmation dialog
     * (MediaStore.createWriteRequest). Only one write flow can be pending at
     * a time.
     */
    private var pendingWriteResult: MethodChannel.Result? = null
    private var pendingPickDirectoryResult: MethodChannel.Result? = null
    private var pendingPickFileResult: MethodChannel.Result? = null

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
        NativeLog.init(this)
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        SharedPreviewBridge.detach(flutterEngine.dartExecutor.binaryMessenger)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        NativeLog.register(this, flutterEngine.dartExecutor.binaryMessenger)
        SharedPreviewBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)
        super.configureFlutterEngine(flutterEngine)
        ProvenancePairWriter.register(this, flutterEngine.dartExecutor.binaryMessenger)
        DownloadControl.register(flutterEngine.dartExecutor.binaryMessenger)
        NativeCollation.register(flutterEngine.dartExecutor.binaryMessenger)

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

        val mediaStore = MediaStoreBridge(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL,
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue())
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deleteMedia" -> runOnUiThread { deleteMedia(call, result) }
                    "requestWriteAccess" -> runOnUiThread { requestWriteAccess(call, result) }
                    // Activity-free reads are shared with the overlay engine.
                    else -> if (!mediaStore.handle(call, result)) result.notImplemented()
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SAF_CHANNEL,
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue())
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDirectory" -> runOnUiThread { pickDirectory(result) }
                    "pickBackupFile" -> runOnUiThread { pickBackupFile(result) }
                    else -> if (!SafStorageBridge(applicationContext).handle(call, result)) result.notImplemented()
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
                val reply = pendingDeleteResult
                val sidecars = pendingDeleteSidecars
                pendingDeleteResult = null
                pendingDeleteSidecars = emptyList()
                Thread {
                    try {
                        val approved = C2paStoragePolicy.finishDelete(resultCode == RESULT_OK, sidecars) {
                            ProvenancePairWriter.deleteSidecars(this, listOf(it))
                        }
                        runOnUiThread { reply?.success(approved) }
                    } catch (_: Exception) {
                        runOnUiThread { reply?.error("sidecar_delete_failed", "图片已删除，但来源边车删除失败", null) }
                    }
                }.start()
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
                        NativeLog.e("EasySaveSAF", "Failed to take persistable URI permission: ${e.message}", e)
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
            pendingDeleteResult = result
            Thread {
                try {
                    val sidecars = ProvenancePairWriter.sidecarsFor(this, ids)
                    val pendingIntent = MediaStore.createDeleteRequest(contentResolver, uris)
                    runOnUiThread {
                        try {
                            pendingDeleteSidecars = sidecars
                            @Suppress("DEPRECATION")
                            startIntentSenderForResult(pendingIntent.intentSender, DELETE_REQUEST_CODE, null, 0, 0, 0)
                        } catch (_: Exception) {
                            pendingDeleteResult = null
                            pendingDeleteSidecars = emptyList()
                            result.error("delete_failed", "Delete request failed", null)
                        }
                    }
                } catch (_: Exception) {
                    runOnUiThread {
                        pendingDeleteResult = null
                        pendingDeleteSidecars = emptyList()
                        result.error("delete_failed", "Delete request failed", null)
                    }
                }
            }.start()
        } catch (e: Exception) {
            pendingDeleteResult = null
            pendingDeleteSidecars = emptyList()
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
            pendingWriteResult = result
            Thread {
                try {
                    val pendingIntent = MediaStore.createWriteRequest(contentResolver, uris)
                    runOnUiThread {
                        try {
                            @Suppress("DEPRECATION")
                            startIntentSenderForResult(pendingIntent.intentSender, WRITE_REQUEST_CODE, null, 0, 0, 0)
                        } catch (_: Exception) {
                            pendingWriteResult = null
                            result.error("write_request_failed", "Write request failed", null)
                        }
                    }
                } catch (_: Exception) {
                    runOnUiThread {
                        pendingWriteResult = null
                        result.error("write_request_failed", "Write request failed", null)
                    }
                }
            }.start()
        } catch (e: Exception) {
            pendingWriteResult = null
            result.error("write_request_failed", e.message, null)
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
        if (!ExternalHandlers.accepts(url) || !isSealInstalled()) return false
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
            NativeLog.e("EasySaveSAF", "Failed to start ACTION_OPEN_DOCUMENT_TREE: ${e.message}", e)
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
            NativeLog.e("EasySaveSAF", "Failed to start ACTION_OPEN_DOCUMENT: ${e.message}", e)
            pendingPickFileResult = null
            result.error("SAF_ERROR", e.message, null)
        }
    }


}
