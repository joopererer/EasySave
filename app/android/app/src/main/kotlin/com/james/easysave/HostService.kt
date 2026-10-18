package com.james.easysave

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * v1.6 background host. Owns the single background FlutterEngine that runs the
 * real parser and DownloadManager (no second implementation), started from a
 * foreground service with no Activity.
 *
 * Engine lifecycle: kept alive while a task is running or the selection panel
 * is open; destroyed together with the service after [IDLE_TIMEOUT_MS] of
 * inactivity. The bubble itself is native and does not depend on the engine.
 */
class HostService : Service() {
    companion object {
        const val TAG = "V16HOST"
        const val CHANNEL_ID = "easysave_host"
        const val NOTIF_ID = 9010
        const val ACTION_SUBMIT = "com.james.easysave.action.SUBMIT"
        const val ACTION_HISTORY_CHANGED = "com.james.easysave.action.HISTORY_CHANGED"
        const val EXTRA_URLS = "urls"
        const val EXTRA_URL = "url"
        const val EXTRA_TEXT = "text"
        const val EXTRA_MODE = "mode"
        const val EXTRA_SOURCE = "source"
        private const val IDLE_TIMEOUT_MS = 60_000L

        /**
         * Start the host and enqueue a task. Must be called while the caller is
         * in the foreground (the bubble entry has the overlay permission; the
         * tile / PROCESS_TEXT entries call this from a transparent Activity).
         */
        fun submit(context: Context, urls: List<String>, mode: String, source: String) {
            val intent = Intent(context, HostService::class.java).apply {
                action = ACTION_SUBMIT
                putStringArrayListExtra(EXTRA_URLS, ArrayList(urls))
                putExtra(EXTRA_MODE, mode)
                putExtra(EXTRA_SOURCE, source)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        /** Same as [submit] but passes free text (PROCESS_TEXT selection). */
        fun submitText(context: Context, text: String, mode: String, source: String) {
            val intent = Intent(context, HostService::class.java).apply {
                action = ACTION_SUBMIT
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_MODE, mode)
                putExtra(EXTRA_SOURCE, source)
            }
            ContextCompat.startForegroundService(context, intent)
        }
    }

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private val pending = ArrayDeque<Map<String, Any?>>()
    private val handler = Handler(Looper.getMainLooper())
    private val idleRunnable = Runnable {
        Log.i(TAG, "Idle ${IDLE_TIMEOUT_MS}ms reached → destroy engine + stopSelf")
        releaseEngine()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        ensureEngine()
        resetIdleTimer()

        if (intent?.action == ACTION_SUBMIT) {
            val urls = intent.getStringArrayListExtra(EXTRA_URLS)
                ?: intent.getStringExtra(EXTRA_URL)?.let { arrayListOf(it) }
                ?: arrayListOf()
            val task = mutableMapOf<String, Any?>(
                "urls" to urls,
                "text" to intent.getStringExtra(EXTRA_TEXT),
                "mode" to (intent.getStringExtra(EXTRA_MODE) ?: "all"),
                "source" to (intent.getStringExtra(EXTRA_SOURCE) ?: "background"),
            )
            enqueue(task)
        }
        return START_NOT_STICKY
    }

    private fun enqueue(task: Map<String, Any?>) {
        if (ready && channel != null) {
            channel?.invokeMethod("submit", task)
        } else {
            pending.addLast(task)
        }
    }

    private fun ensureEngine() {
        if (engine != null) return
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            try {
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)
            } catch (e: Exception) {
                Log.i(TAG, "FlutterLoader init skipped: ${e.message}")
            }

            val e = FlutterEngine(applicationContext, null, true)
            engine = e
            val ch = MethodChannel(e.dartExecutor.binaryMessenger, "easysave/bgtask")
            channel = ch
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> {
                        ready = true
                        Log.i(TAG, "BG engine ready")
                        while (pending.isNotEmpty()) {
                            ch.invokeMethod("submit", pending.removeFirst())
                        }
                        resetIdleTimer()
                        result.success(null)
                    }
                    "log" -> {
                        Log.i(TAG, call.arguments as? String ?: "")
                        result.success(null)
                    }
                    "notify" -> {
                        updateNotification(call.arguments as? String ?: "")
                        result.success(null)
                    }
                    "historyChanged" -> {
                        // Tell the running main UI to refresh its history page.
                        sendBroadcast(
                            Intent(ACTION_HISTORY_CHANGED).setPackage(packageName)
                        )
                        result.success(null)
                    }
                    "openApp" -> {
                        openApp()
                        result.success(null)
                    }
                    "keepAlive" -> {
                        resetIdleTimer()
                        result.success(null)
                    }
                    "idle" -> {
                        resetIdleTimer()
                        result.success(null)
                    }
                    "stop" -> {
                        releaseEngine()
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
            Log.e(TAG, "ensureEngine FAILED: $e", e)
            updateNotification("后台引擎启动失败: ${e.message}")
            stopSelf()
        }
    }

    private fun resetIdleTimer() {
        handler.removeCallbacks(idleRunnable)
        handler.postDelayed(idleRunnable, IDLE_TIMEOUT_MS)
    }

    private fun releaseEngine() {
        handler.removeCallbacks(idleRunnable)
        try {
            channel?.setMethodCallHandler(null)
            engine?.destroy()
        } catch (_: Exception) {
        }
        engine = null
        channel = null
        ready = false
        pending.clear()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION") stopForeground(true)
        }
        stopSelf()
    }

    private fun contentIntent(): PendingIntent {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        else
            PendingIntent.FLAG_UPDATE_CURRENT
        return PendingIntent.getActivity(this, 0, intent, flags)
    }

    private fun openApp() {
        try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent(this, MainActivity::class.java)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "openApp failed: $e")
        }
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "EasySave 后台任务", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val notif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("EasySave 后台任务")
            .setContentText("准备中…")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(contentIntent())
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
            .setContentTitle("EasySave 后台任务")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(contentIntent())
            .setOngoing(true)
            .build()
        nm.notify(NOTIF_ID, notif)
    }

    override fun onDestroy() {
        releaseEngine()
        super.onDestroy()
    }
}
