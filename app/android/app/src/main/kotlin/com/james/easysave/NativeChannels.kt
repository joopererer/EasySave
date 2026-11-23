package com.james.easysave

import android.content.Context
import com.james.easysave.transfer.TransferChannels
import io.flutter.plugin.common.BinaryMessenger

/**
 * The channels every FlutterEngine needs, registered in one place.
 *
 * Build 55 device report: after the background engine was destroyed for being
 * idle and then rebuilt, a submitted task logged `submit: ...` and nothing
 * else — no ShortLink, no ParseWebView, no batch. The engine had been created
 * twice, and the two creation sites ([HostService] and [MainActivity]) each
 * listed their channels by hand, so a channel added to one of them could be
 * missing (or silently left in the destroyed engine's state) in the other.
 *
 * [registerShared] is now the only way either engine registers these, and it
 * is called on **every** engine creation — first or rebuilt, foreground or
 * background. Channels that need an Activity (permission dialogs, pickers, the
 * tile, the bubble) stay in [MainActivity], because they cannot work without
 * one.
 */
internal object NativeChannels {
    /**
     * Registers the engine-agnostic channels on [messenger].
     *
     * [background] tells [SharedPreviewBridge] which engine owns the
     * thumbnail-file channel: the one that renders the overlay/background
     * previews.
     */
    fun registerShared(
        context: Context,
        messenger: BinaryMessenger,
        background: Boolean = false,
    ) {
        NativeLog.register(context, messenger)
        // Rebuilt engine: the previous engine's callback must not make this
        // one skip its own registration.
        NetworkStatusChannel.register(context, messenger)
        SharedPreviewBridge.register(context, messenger, background = background)
        ProvenancePairWriter.register(context, messenger)
        DownloadControl.register(messenger)
        TransferChannels.register(context, messenger)
    }
}
