package com.james.easysave.transfer

import android.app.Notification
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
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.james.easysave.MainActivity
import com.james.easysave.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * 传输前台服务（TransferService）。
 *
 * 属性与规范：
 * - foregroundServiceType=dataSync；
 * - Manifest 声明 FOREGROUND_SERVICE 与 FOREGROUND_SERVICE_DATA_SYNC；
 * - 单一固定通知 ID（9200）；
 * - 没有活动任务 60 秒后自行停止；
 * - 实现 onTimeout(int, int)（Android 15 起 24 小时内限 6 小时）：停止所有写入，任务转 interrupted，原因 fgs_timeout，然后 stopSelf()；
 * - 不从 BOOT_COMPLETED 启动。
 */
class TransferService : Service() {

    companion object {
        const val NOTIFICATION_CHANNEL_ID = "easysave_transfer"
        const val NOTIFICATION_ID = 9200
        const val IDLE_STOP_DELAY_MS = 60_000L

        const val ACTION_START = "com.james.easysave.transfer.action.START"
        const val ACTION_STOP = "com.james.easysave.transfer.action.STOP"

        @Volatile
        var instance: TransferService? = null

        @Volatile
        private var sharedScheduler: TransferScheduler? = null

        @Volatile
        var sharedNetworkChecker: AndroidNetworkCapabilityChecker? = null

        @Synchronized
        fun getOrCreateScheduler(context: Context): TransferScheduler {
            sharedScheduler?.let { return it }
            val appContext = context.applicationContext
            val store = TransferStore(appContext)
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val networkChecker = AndroidNetworkCapabilityChecker(appContext).also {
                sharedNetworkChecker = it
            }
            val scheduler = TransferScheduler(
                store = store,
                workerFactory = { job ->
                    if (job.fakePlan != null) {
                        FakeWorker()
                    } else {
                        HttpWorker(context = appContext)
                    }
                },
                scope = scope,
                networkChecker = networkChecker,
                eventListener = { event ->
                    TransferChannels.broadcastEvent(event)
                },
                onIdleChanged = { isIdle ->
                    instance?.onIdleChanged(isIdle)
                },
                transfersDir = java.io.File(appContext.filesDir, "transfers"),
                publisher = MediaStorePublisher(appContext),
            )
            // 启动时恢复
            scheduler.handleRestoreFromStore()
            sharedScheduler = scheduler
            return scheduler
        }

        fun startService(context: Context) {
            val intent = Intent(context, TransferService::class.java).apply {
                action = ACTION_START
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (t: Throwable) {
                TransferLog.e("Failed to start TransferService: ${t.message}", t)
            }
        }
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var idleRunnable: Runnable? = null
    private var isForegroundStarted = false

    lateinit var scheduler: TransferScheduler
    private var networkMonitor: TransferNetworkMonitor? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        scheduler = getOrCreateScheduler(this)

        val checker = sharedNetworkChecker ?: AndroidNetworkCapabilityChecker(applicationContext).also {
            sharedNetworkChecker = it
        }
        networkMonitor = TransferNetworkMonitor(this, scheduler, checker).apply {
            start()
        }

        createNotificationChannel()
        startForegroundNotification()
        TransferLog.i("TransferService created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundNotification()
        val action = intent?.action
        if (action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "EasySave 传输服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "EasySave 后台媒体下载与云端传输服务"
                setShowBadge(false)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, flags)

        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("EasySave 传输服务")
            .setContentText("后台传输服务运行中")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun startForegroundNotification() {
        if (!isForegroundStarted) {
            val notification = buildNotification()
            val fgsType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            }
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, fgsType)
            isForegroundStarted = true
        }
    }

    fun onIdleChanged(isIdle: Boolean) {
        mainHandler.post {
            if (isIdle) {
                MainThreadLagMonitor.stop()
                if (idleRunnable == null) {
                    TransferLog.i("No active transfer tasks, 60s idle countdown started")
                    val runnable = Runnable {
                        TransferLog.i("idle stop: 60s idle timeout reached without active tasks → stopSelf")
                        MainThreadLagMonitor.stop()
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    }
                    idleRunnable = runnable
                    mainHandler.postDelayed(runnable, IDLE_STOP_DELAY_MS)
                }
            } else {
                MainThreadLagMonitor.start(serviceScope)
                idleRunnable?.let {
                    mainHandler.removeCallbacks(it)
                    idleRunnable = null
                    TransferLog.i("Active transfer tasks present, 60s idle countdown cancelled")
                }
            }
        }
    }

    /**
     * Android 15 (API 35) 起系统对 dataSync 前台服务 24 小时内限 6 小时：
     * 停止所有写入，任务转 interrupted，原因 fgs_timeout，然后 stopSelf()。
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        super.onTimeout(startId, fgsType)
        TransferLog.w("onTimeout reached for dataSync service (startId=$startId, fgsType=$fgsType). Transitioning all running jobs to interrupted with reason fgs_timeout.")
        scheduler.onTimeout("fgs_timeout")
        MainThreadLagMonitor.stop()
        stopSelf()
    }

    override fun onDestroy() {
        TransferLog.i("TransferService destroying")
        networkMonitor?.stop()
        networkMonitor = null
        MainThreadLagMonitor.stop()
        idleRunnable?.let { mainHandler.removeCallbacks(it) }
        serviceScope.cancel()
        instance = null
        super.onDestroy()
    }
}
