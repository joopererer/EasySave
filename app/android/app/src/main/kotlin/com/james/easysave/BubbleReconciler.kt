package com.james.easysave

import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log

/**
 * Reconciles the floating bubble lifecycle on app launch, app update, and system boot.
 */
object BubbleReconciler {
    const val TAG = OverlayService.TAG

    enum class ReconcileAction {
        START,
        ALREADY_RUNNING,
        SYNC_DISABLED,
        SKIP_DISABLED,
    }

    /**
     * Reconcile bubble state.
     *
     * @param context Android context
     * @param trigger Cause of the check (e.g. "package_replaced", "boot_completed", "main_activity")
     * @param canDrawOverlays Overrideable overlay permission status (for testing or direct check)
     * @param startService Callback to start the overlay service
     * @param isServiceRunning Callback to check if the overlay service is already active
     */
    fun reconcile(
        context: Context,
        trigger: String,
        canDrawOverlays: Boolean = Settings.canDrawOverlays(context),
        startService: (Context) -> Unit = { OverlayService.start(it) },
        isServiceRunning: () -> Boolean = { OverlayService.isRunning },
    ): ReconcileAction {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean("flutter.bubbleEnabled", false)

        val action: ReconcileAction
        if (enabled) {
            if (canDrawOverlays) {
                if (!isServiceRunning()) {
                    startService(context)
                    action = ReconcileAction.START
                } else {
                    action = ReconcileAction.ALREADY_RUNNING
                }
            } else {
                // Permission was revoked: synchronize setting switch to false per v1.6 rules.
                prefs.edit().putBoolean("flutter.bubbleEnabled", false).apply()
                try {
                    context.sendBroadcast(Intent(OverlayService.ACTION_BUBBLE_STATE))
                } catch (e: Exception) {
                    Log.e(TAG, "send ACTION_BUBBLE_STATE broadcast failed: $e")
                }
                action = ReconcileAction.SYNC_DISABLED
            }
        } else {
            action = ReconcileAction.SKIP_DISABLED
        }

        val started = (action == ReconcileAction.START)
        Log.i(
            TAG,
            "reconcile trigger=$trigger enabled=$enabled canDraw=$canDrawOverlays isRunning=${isServiceRunning()} action=$action started=$started"
        )
        return action
    }
}
