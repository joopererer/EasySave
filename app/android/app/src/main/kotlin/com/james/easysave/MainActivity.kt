package com.james.easysave

import android.content.ContentUris
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SEAL_CHANNEL = "easysave/seal"
        private const val SEAL_PACKAGE = "com.junkfood.seal"
        private const val MEDIA_CHANNEL = "easysave/media"
        private const val DELETE_REQUEST_CODE = 50021
    }

    /**
     * Result callback for the system's batch-delete confirmation dialog
     * (MediaStore.createDeleteRequest). Only one delete flow can be pending at
     * a time; the Dart side never issues concurrent requests.
     */
    private var pendingDeleteResult: MethodChannel.Result? = null

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
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == DELETE_REQUEST_CODE) {
            pendingDeleteResult?.success(resultCode == RESULT_OK)
            pendingDeleteResult = null
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

    private fun isSealInstalled(): Boolean {
        return try {
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
}
