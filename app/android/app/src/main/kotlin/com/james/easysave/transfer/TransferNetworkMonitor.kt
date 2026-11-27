package com.james.easysave.transfer

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import java.util.concurrent.atomic.AtomicInteger

/**
 * 传输服务网络状态监听器。
 *
 * 规则：
 * - 整个服务生命周期内只用 registerDefaultNetworkCallback 注册一次，在 onDestroy 中注销；
 * - 严禁 requestNetwork，严禁在每次进入 waiting_network 时重复注册；
 * - 记录日志：[XFER] net_callback register count=... / unregister count=...
 * - 只有网络从「无可用」变为「可用」时才触发恢复逻辑。初始注册时如果网络本来就是可用的，不算恢复，不唤醒。
 */
class TransferNetworkMonitor(
    private val context: Context,
    private val scheduler: TransferScheduler,
    private val networkChecker: NetworkCapabilityChecker,
) {
    companion object {
        val totalRegisterCount = AtomicInteger(0)
        val totalUnregisterCount = AtomicInteger(0)

        fun resetCounts() {
            totalRegisterCount.set(0)
            totalUnregisterCount.set(0)
        }
    }

    private var connectivityManager: ConnectivityManager? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    // 记录之前是否处于不可用状态
    @Volatile
    var wasOffline: Boolean = false

    @Volatile
    private var lastNetwork: Network? = null

    @Synchronized
    fun start() {
        if (callback != null) {
            TransferLog.w("net_callback already registered, skipping duplicate registration")
            return
        }
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        connectivityManager = cm
        if (cm == null) return

        val initiallyValidated = networkChecker.isDefaultNetworkValidated()
        wasOffline = !initiallyValidated
        lastNetwork = null
        TransferLog.i("net_callback initial_validated=$initiallyValidated was_offline=$wasOffline")

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val switched = lastNetwork != null && lastNetwork != network
                lastNetwork = network
                checkAndDispatch(networkSwitched = switched)
            }

            override fun onLost(network: Network) {
                checkAndDispatch()
            }

            override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                checkAndDispatch()
            }
        }

        try {
            cm.registerDefaultNetworkCallback(cb)
            val count = totalRegisterCount.incrementAndGet()
            TransferLog.i("[XFER] net_callback register count=$count")
            callback = cb
        } catch (t: Throwable) {
            TransferLog.e("registerDefaultNetworkCallback failed: ${t.message}", t)
        }
    }

    fun checkAndDispatch(networkSwitched: Boolean = false) {
        val isValidated = networkChecker.isDefaultNetworkValidated()
        if (!isValidated) {
            wasOffline = true
            scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = false, wasOffline = true))
        } else {
            if (wasOffline) {
                // 从「无可用」变为「可用」：通知调度器网络恢复（需稳定 3 秒后重排）
                wasOffline = false
                scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = true, wasOffline = true))
            } else if (networkSwitched) {
                // 默认网络切换（如 Wi-Fi <-> 蜂窝）：通知调度器刷新 15 秒宽限窗口，不触发恢复重排
                scheduler.send(SchedulerEvent.NetworkChanged(isAvailable = true, wasOffline = false))
            } else {
                // 原来就可用，初次回调或未断网变动：不算恢复，不唤醒
                TransferLog.i("net_callback online without disconnect -> no recovery needed")
            }
        }
    }

    @Synchronized
    fun stop() {
        val cb = callback ?: return
        callback = null
        try {
            connectivityManager?.unregisterNetworkCallback(cb)
            val count = totalUnregisterCount.incrementAndGet()
            TransferLog.i("[XFER] net_callback unregister count=$count")
        } catch (t: Throwable) {
            TransferLog.e("unregisterNetworkCallback failed: ${t.message}", t)
        }
    }
}

