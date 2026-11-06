package com.james.easysave

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SafStorageBridgeTest {
    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        var background = false
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun makeBackgroundTaskQueue(options: BinaryMessenger.TaskQueueOptions): BinaryMessenger.TaskQueue =
            object : BinaryMessenger.TaskQueue {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler != null) handlers[channel] = handler else handlers.remove(channel)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?, queue: BinaryMessenger.TaskQueue?) {
            background = queue != null
            setMessageHandler(channel, handler)
        }
        fun call(method: String, args: Map<String, Any?> = emptyMap()): Any? {
            var answer: Any? = null
            val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, args))
            message.flip()
            handlers.getValue("easysave/saf").onMessage(message) { bytes ->
                bytes!!.flip()
                answer = StandardMethodCodec.INSTANCE.decodeEnvelope(bytes)
            }
            return answer
        }
    }

    @Test fun backgroundEngineHasActualSafChannelOnWorkerQueue() {
        val messenger = Messenger()
        SafStorageBridge.register(RuntimeEnvironment.getApplication(), messenger)
        assertTrue(messenger.background)
        assertEquals(false, messenger.call("checkDirectoryAccess"))
        assertEquals(false, messenger.call("checkDirectoryAccess", mapOf("treeUri" to "content://fixture/tree/missing")))
    }

    @Test fun backgroundChannelRespondsToBackupStorageMethods() {
        val messenger = Messenger()
        SafStorageBridge.register(RuntimeEnvironment.getApplication(), messenger)
        assertEquals(emptyMap<String, Boolean>(), messenger.call("deleteDocuments", mapOf("uris" to emptyList<String>())))
        assertEquals(emptyList<Any>(), messenger.call("listBackupDirectory", mapOf("treeUri" to "content://fixture/tree/missing")))
        assertNull(messenger.call("getDirectoryDisplayName", mapOf("treeUri" to "content://fixture/tree/missing")))
    }
}
