package com.james.easysave

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class ProvenancePairWriterTest {
    @Test fun keepsEntireFilenameIncludingExtension() {
        assertEquals("post_1.jpg.xmp", ProvenancePairWriter.sidecarName("post_1.jpg"))
        assertEquals("post (1).mp4.xmp", ProvenancePairWriter.sidecarName("post (1).mp4"))
    }
    @Test fun refusesPathsAndEmptyNames() {
        for (name in listOf("", "..", "../photo.jpg", "dir/photo.jpg", "dir\\photo.jpg")) {
            assertTrue(name, runCatching { ProvenancePairWriter.sidecarName(name) }.isFailure)
        }
    }

    @Test fun dispatchBackgroundWorkRunsOffCallerThread() {
        val callerThreadId = Thread.currentThread().id
        val workerThreadId = AtomicReference<Long>()
        val workerThreadName = AtomicReference<String>()
        val latch = CountDownLatch(1)

        ProvenancePairWriter.dispatchBackgroundWork(onMain = { it() }) {
            workerThreadId.set(Thread.currentThread().id)
            workerThreadName.set(Thread.currentThread().name)
            latch.countDown()
        }

        assertTrue("Background work timed out", latch.await(5, TimeUnit.SECONDS))
        assertNotEquals(callerThreadId, workerThreadId.get())
        assertTrue(workerThreadName.get()?.startsWith("EasySave-MediaIO") == true)
    }
}
