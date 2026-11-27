package com.james.easysave

import io.flutter.plugin.common.BinaryMessenger
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.nio.ByteBuffer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NativeChannelsTest {

    private class RecordingBinaryMessenger : BinaryMessenger {
        val registeredChannels = mutableSetOf<String>()

        override fun send(channel: String, message: ByteBuffer?) {}

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler != null) {
                registeredChannels.add(channel)
            }
        }

        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
            taskQueue: BinaryMessenger.TaskQueue?,
        ) {
            if (handler != null) {
                registeredChannels.add(channel)
            }
        }

        override fun makeBackgroundTaskQueue(options: BinaryMessenger.TaskQueueOptions): BinaryMessenger.TaskQueue {
            return object : BinaryMessenger.TaskQueue {}
        }
    }

    @Test
    fun registerShared_inBackgroundMode_registersAllHostServiceChannelsWithoutActivity() {
        val appContext = RuntimeEnvironment.getApplication()
        val messenger = RecordingBinaryMessenger()

        NativeChannels.registerShared(appContext, messenger, background = true)
        SafStorageBridge.register(appContext, messenger)
        MediaStoreBridge.register(appContext, messenger)

        assertTrue(messenger.registeredChannels.contains("easysave/dev_log"))
        assertTrue(messenger.registeredChannels.contains("easysave/provenance_pair"))
        assertTrue(messenger.registeredChannels.contains("easysave/transfer"))
        assertTrue(messenger.registeredChannels.contains("easysave/transfer/events"))
    }
}

