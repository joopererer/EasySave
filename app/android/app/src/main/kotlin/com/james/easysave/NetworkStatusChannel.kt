package com.james.easysave

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * System connectivity for the download UI (v1.11 batch 2).
 *
 * Display only: Dart uses this to show "当前无网络，联网后自动开始" /
 * "等待网络…联网后自动继续". Nothing here queues, retries or cancels a
 * download — the downloader keeps its own behaviour while offline and resumes
 * by itself once the connection is back.
 *
 * A network counts as online only when the system reports both INTERNET and
 * VALIDATED, so "connected to a Wi-Fi without internet" is offline too.
 */
internal object NetworkStatusChannel {
    private const val channelName = "easysave/connectivity"

    @Volatile private var manager: ConnectivityManager? = null
    @Volatile private var channel: MethodChannel? = null
    @Volatile private var callback: ConnectivityManager.NetworkCallback? = null
    private val main = Handler(Looper.getMainLooper())

    fun register(context: Context, messenger: BinaryMessenger) {
        val cm = context.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        manager = cm
        val ch = MethodChannel(messenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "isOnline" -> result.success(isOnline(cm))
                else -> result.notImplemented()
            }
        }
        if (cm == null || callback != null) return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = push(cm)
            override fun onLost(network: Network) = push(cm)
            override fun onCapabilitiesChanged(
                network: Network,
                caps: NetworkCapabilities,
            ) = push(cm)
        }
        try {
            cm.registerDefaultNetworkCallback(cb)
            callback = cb
        } catch (_: Exception) {
            // Without a callback the UI keeps the last reading; downloads are
            // unaffected either way.
        }
    }

    /** Unregisters the system callback (engine teardown). */
    fun detach() {
        val cm = manager
        val cb = callback
        callback = null
        channel = null
        if (cm != null && cb != null) {
            try {
                cm.unregisterNetworkCallback(cb)
            } catch (_: Exception) {
            }
        }
    }

    private fun push(cm: ConnectivityManager) {
        val online = isOnline(cm)
        main.post { channel?.invokeMethod("online", online) }
    }

    private fun isOnline(cm: ConnectivityManager?): Boolean {
        if (cm == null) return true
        return try {
            val network = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(network) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        } catch (_: Exception) {
            true
        }
    }
}
