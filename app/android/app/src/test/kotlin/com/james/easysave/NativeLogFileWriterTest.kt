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
        val jobs = (0 until count).map { index ->
            pool.submit {
                val source = listOf("Foreground", "Background", "PreviewPlayer")[index % 3]
                NativeLogFileWriter(file).append("[INFO] [$source] record=$index 内容完整\n")
            }
        }
        pool.shutdown()
        assertTrue(pool.awaitTermination(10, TimeUnit.SECONDS))
        jobs.forEach { it.get() }

        val lines = file.readLines()
        assertEquals(count, lines.size)
        assertTrue(lines.all { it.matches(Regex("""\[INFO] \[(Foreground|Background|PreviewPlayer)] record=\d+ 内容完整""")) })
        assertEquals(count, lines.toSet().size)
    }

    @Test
    fun embeddedNewlinesCannotSplitARecord() {
        val file = Files.createTempDirectory("easysave-log-lines").resolve("v16dl.log").toFile()
        NativeLogFileWriter(file).append("[INFO] [Native] first\nsecond\rthird\n")
        assertEquals(listOf("[INFO] [Native] first\\nsecond\\rthird"), file.readLines())
    }

    @Test
    fun rotationExportAndClearUseTheSameSink() {
        val directory = Files.createTempDirectory("easysave-log-rotate")
        val file = directory.resolve("v16dl.log").toFile()
        file.writeText("x".repeat(1024 * 1024))
        val writer = NativeLogFileWriter(file)
        writer.append("[INFO] [NativeLog] ready\n")
        assertEquals(1024 * 1024L, directory.resolve("v16dl.log.1").toFile().length())
        val target = directory.resolve("export.log").toFile()
        assertEquals(target.path, writer.export(target))
        assertEquals(file.readText(), target.readText())
        writer.clear()
        assertTrue(!file.exists())
        assertTrue(!directory.resolve("v16dl.log.1").toFile().exists())
    }
}
