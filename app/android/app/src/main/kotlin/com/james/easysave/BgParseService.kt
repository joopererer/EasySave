package com.james.easysave

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * v1.6 validation: run a standalone FlutterEngine (no Activity) inside a
 * foreground service and parse links with the existing Dart parser.
 */
class BgParseService : Service() {
    companion object {
        const val TAG = "V16VAL"
        const val CHANNEL_ID = "v16test"
        const val NOTIF_ID = 9001
        const val EXTRA_URLS = "urls"
    }

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val urls = intent?.getStringArrayListExtra(EXTRA_URLS) ?: arrayListOf()
        startForegroundCompat("启动后台引擎…")
        if (engine == null) {
            startEngine(urls)
        } else {
            channel?.invokeMethod("run", urls)
        }
        return START_NOT_STICKY
    }

    private fun startEngine(urls: List<String>) {
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            try {
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)
            } catch (e: Exception) {
                // Already initialised by the main engine in the same process.
                Log.i(TAG, "FlutterLoader init skipped: ${e.message}")
            }

            val e = FlutterEngine(applicationContext, null, true)
            engine = e
            val ch = MethodChannel(e.dartExecutor.binaryMessenger, "easysave/bgtest")
            channel = ch
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> {
                        Log.i(TAG, "BG engine ready; sending ${urls.size} urls")
                        ch.invokeMethod("run", urls)
                        result.success(null)
                    }
                    "log" -> {
                        val msg = call.arguments as? String ?: ""
                        Log.i(TAG, msg)
                        updateNotification(msg)
                        result.success(null)
                    }
                    "done" -> {
                        Log.i(TAG, "BG parse DONE")
                        updateNotification("验证完成，见 Logcat: V16VAL")
                        stopSelf()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundMain")
            )
            Log.i(TAG, "FlutterEngine.executeDartEntrypoint(backgroundMain) called")
        } catch (e: Exception) {
            Log.e(TAG, "startEngine FAILED: $e", e)
            updateNotification("后台引擎启动失败: ${e.message}")
            stopSelf()
        }
    }

    private fun startForegroundCompat(text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "v1.6 验证", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val notif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("v1.6 后台解析验证")
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this, NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("v1.6 后台解析验证")
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .build()
        nm.notify(NOTIF_ID, notif)
    }

    override fun onDestroy() {
        try {
            channel?.setMethodCallHandler(null)
            engine?.destroy()
        } catch (_: Exception) {
        }
        engine = null
        channel = null
        super.onDestroy()
    }
}
