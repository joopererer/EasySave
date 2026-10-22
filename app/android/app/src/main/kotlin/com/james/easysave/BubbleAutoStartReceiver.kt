package com.james.easysave

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Automatically reconciles and restores the floating bubble service after
 * an app update (ACTION_MY_PACKAGE_REPLACED) or device boot (ACTION_BOOT_COMPLETED).
 */
class BubbleAutoStartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        val ctx = context ?: return
        val action = intent?.action ?: return
        val trigger = when (action) {
            Intent.ACTION_MY_PACKAGE_REPLACED -> "package_replaced"
            Intent.ACTION_BOOT_COMPLETED -> "boot_completed"
            else -> action
        }
        BubbleReconciler.reconcile(ctx, trigger)
    }
}
