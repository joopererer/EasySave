package com.james.easysave.transfer

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * 主线程 Lag 监控（自检期间每 10 秒记一行 [XFER] main_lag_ms）。
 */
object MainThreadLagMonitor {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var isMonitoring = false
    private var job: Job? = null

    @Synchronized
    fun start(scope: CoroutineScope) {
        if (isMonitoring) return
        isMonitoring = true
        job = scope.launch(Dispatchers.Default) {
            while (isActive && isMonitoring) {
                delay(10_000L)
                if (!isActive || !isMonitoring) break
                val start = SystemClock.uptimeMillis()
                mainHandler.post {
                    val lag = SystemClock.uptimeMillis() - start
                    TransferLog.i("main_lag_ms=$lag")
                }
            }
        }
        TransferLog.i("MainThreadLagMonitor started")
    }

    @Synchronized
    fun stop() {
        if (!isMonitoring) return
        isMonitoring = false
        job?.cancel()
        job = null
        TransferLog.i("MainThreadLagMonitor stopped")
    }
}

