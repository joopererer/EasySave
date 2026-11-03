package com.james.easysave

import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeLogFileWriterTest {
    @Test
    fun concurrentWritersKeepEachRecordOnItsOwnLine() {
        val directory = Files.createTempDirectory("easysave-native-log")
        val file = directory.resolve("v16dl.log").toFile()
        val pool = Executors.newFixedThreadPool(8)
        val count = 200
        repeat(count) { index ->
            pool.submit {
                NativeLogFileWriter(file).append("[INFO] [Test] record=$index\n")
            }
        }
        pool.shutdown()
        assertTrue(pool.awaitTermination(10, TimeUnit.SECONDS))

        val lines = file.readLines()
        assertEquals(count, lines.size)
        assertTrue(lines.all { it.matches(Regex("""\[INFO] \[Test] record=\d+""")) })
    }
}
