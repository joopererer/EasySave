package com.james.easysave

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile ("EasySave 下载"). A TileService has no window focus, so
 * it cannot read the clipboard itself: clicking launches the transparent
 * [ClipboardReaderActivity], which reads the clipboard and — on a supported
 * link — starts [HostService] with mode=all.
 *
 * The tile shows an active state + progress subtitle while a download runs;
 * [HostService] pushes state here via [pushState].
 */
class EasySaveTileService : TileService() {
    companion object {
        @Volatile private var active = false
        @Volatile private var subtitle: String? = null

        /** Push a new state to the tile (called by HostService). */
        fun pushState(context: Context, isActive: Boolean, text: String?) {
            active = isActive
            subtitle = text
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    requestListeningState(
                        context, ComponentName(context, EasySaveTileService::class.java)
                    )
                }
            } catch (_: Exception) {
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        // Read the clipboard via a transparent Activity (the tile itself has no
        // focus). On a link, download in the background.
        ClipboardReaderActivity.listener = { text ->
            val clean = text?.trim().orEmpty()
            if (clean.contains("http", ignoreCase = true)) {
                HostService.submitText(
                    this, clean, "all", "background", "剪贴板里没有可解析的链接"
                )
            }
            // No link: ClipboardReaderActivity already toasted the hint.
        }
        val intent = Intent(this, ClipboardReaderActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(ClipboardReaderActivity.EXTRA_EMPTY_MESSAGE, "剪贴板里没有可解析的链接")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pi = PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            startActivityAndCollapse(pi)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        tile.state = if (active) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.icon = Icon.createWithResource(this, R.drawable.ic_qs_easysave)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = subtitle
        }
        tile.updateTile()
    }
}
