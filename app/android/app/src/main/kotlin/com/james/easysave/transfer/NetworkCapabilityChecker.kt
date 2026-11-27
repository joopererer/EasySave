package com.james.easysave.transfer

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/**
 * 默认网络有效性检查接口（便于单元测试注入与模拟）。
 */
interface NetworkCapabilityChecker {
    fun isDefaultNetworkValidated(): Boolean
}

class AndroidNetworkCapabilityChecker(private val context: Context) : NetworkCapabilityChecker {
    @Volatile
    var simulatedValidated: Boolean? = null

    override fun isDefaultNetworkValidated(): Boolean {
        simulatedValidated?.let { return it }
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }
}

