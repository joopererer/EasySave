package com.james.easysave

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

class MediaHeaderReaderMp4Test {

    private val videoFiles = listOf(
        "local-video.mp4",
        "mov-no-xmp.mov",
        "mov-xmp-uuid.mov",
        "mp4-64bit-box.mp4",
        "mp4-interrupted-append.mp4",
        "mp4-mdat-uuid-noise.mp4",
        "mp4-multiple-xmp.mp4",
        "mp4-no-xmp.mp4",
        "mp4-size-zero-mdat.mp4",
        "mp4-truncated-mdat.mp4",
        "mp4-truncated-xmp.mp4",
        "mp4-xmp-uuid.mp4",
    )

    private fun findVectorsDir(): File {
        val candidates = listOf(
            File("../../../docs/provenance-spec/test-vectors"),
            File("../../docs/provenance-spec/test-vectors"),
            File("../docs/provenance-spec/test-vectors"),
            File("docs/provenance-spec/test-vectors"),
            File("D:/workspace/IdeaProjects/EasySave/docs/provenance-spec/test-vectors"),
        )
        return candidates.firstOrNull { it.isDirectory }
            ?: error("test-vectors directory not found in candidates: $candidates")
    }

    @Test
    fun testAllTwelveVideoVectorsCovered() {
        val dir = findVectorsDir()
        val foundVideos = dir.listFiles { _, name -> name.endsWith(".mp4") || name.endsWith(".mov") }
            ?.map { it.name }
            ?.sorted() ?: emptyList()

        assertEquals("Expected exactly 12 video test files in spec test-vectors", 12, foundVideos.size)
        assertEquals(videoFiles.sorted(), foundVideos)
    }

    @Test
    fun testReadMp4OnAllTwelveVideoFilesAgainstExpectedJson() {
        val dir = findVectorsDir()

        for (filename in videoFiles) {
            val videoFile = File(dir, filename)
            assertTrue("Video file must exist: $filename", videoFile.exists())

            val expectedJsonFile = File(dir, "$filename.expected.json")
            assertTrue("Expected json must exist: $expectedJsonFile", expectedJsonFile.exists())
            val expectedJson = JSONObject(expectedJsonFile.readText(Charsets.UTF_8))

            val bytes = RandomAccessFile(videoFile, "r").use { raf ->
                MediaHeaderReader.readMp4(RandomAccessFileSource(raf))
            }

            // local-video.mp4 has no embedded XMP (only a sidecar file), so embedded read returns null
            val expectNoEmbeddedXmp = expectedJson.optBoolean("_none", false) || filename == "local-video.mp4"

            if (expectNoEmbeddedXmp) {
                assertNull("File $filename expected no embedded XMP, but readMp4 returned bytes", bytes)
            } else {
                assertNotNull("File $filename expected embedded XMP, but readMp4 returned null", bytes)
                val bytesNonNull = bytes!!
                assertTrue("File $filename returned empty bytes", bytesNonNull.isNotEmpty())

                // Verify that the returned bytes start with a valid MP4 box header and contain XMP UUID
                assertTrue(
                    "Box header must be at least 24 bytes (8 header + 16 uuid)",
                    bytesNonNull.size >= 24,
                )
                val type = String(bytesNonNull, 4, 4, Charsets.US_ASCII)
                assertEquals("Returned box type must be uuid", "uuid", type)

                // Verify assetId from expected.json is present in the XML text of the returned box
                val expectedAssetId = expectedJson.getString("assetId")
                val text = String(bytesNonNull, Charsets.UTF_8)
                assertTrue(
                    "Returned bytes for $filename must contain assetId $expectedAssetId",
                    text.contains(expectedAssetId),
                )

                // If expected.json specifies title, verify it is present in the XML
                if (expectedJson.has("title")) {
                    val expectedTitle = expectedJson.getString("title")
                    assertTrue(
                        "Returned bytes for $filename must contain title $expectedTitle",
                        text.contains(expectedTitle),
                    )
                }
            }
        }
    }

    @Test
    fun testFileChannelSourceEquivalence() {
        val dir = findVectorsDir()
        val file = File(dir, "mp4-xmp-uuid.mp4")

        val fromRaf = RandomAccessFile(file, "r").use { raf ->
            MediaHeaderReader.readMp4(RandomAccessFileSource(raf))
        }

        val fromChannel = java.io.FileInputStream(file).channel.use { channel ->
            MediaHeaderReader.readMp4(FileChannelSource(channel))
        }

        assertNotNull(fromRaf)
        assertNotNull(fromChannel)
        assertTrue(fromRaf!!.contentEquals(fromChannel!!))
    }

    @Test
    fun testIsMp4RejectsNonMp4Headers() {
        val nonMp4 = ByteArray(32) { 0 }
        assertFalse(MediaHeaderReader.isMp4(ByteArraySource(nonMp4)))

        // PNG header
        val pngHeader = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        assertFalse(MediaHeaderReader.isMp4(ByteArraySource(pngHeader)))

        assertNull(MediaHeaderReader.readMp4(ByteArraySource(pngHeader)))
    }

    @Test
    fun testInterruptedAppendReturnsPriorCompleteBox() {
        val dir = findVectorsDir()
        val file = File(dir, "mp4-interrupted-append.mp4")

        val bytes = RandomAccessFile(file, "r").use { raf ->
            MediaHeaderReader.readMp4(RandomAccessFileSource(raf))
        }

        assertNotNull("Interrupted append must preserve prior complete box", bytes)
        val text = String(bytes!!, Charsets.UTF_8)
        val exp = JSONObject(File(dir, "mp4-interrupted-append.mp4.expected.json").readText())
        assertTrue(text.contains(exp.getString("assetId")))
    }

    @Test
    fun testMdatNoiseDoesNotExtractMdatNoiseBox() {
        val dir = findVectorsDir()
        val file = File(dir, "mp4-mdat-uuid-noise.mp4")

        val bytes = RandomAccessFile(file, "r").use { raf ->
            MediaHeaderReader.readMp4(RandomAccessFileSource(raf))
        }

        assertNotNull(bytes)
        val text = String(bytes!!, Charsets.UTF_8)
        // Noise box inside mdat has platform=fake, while top-level trailing box has platform=web
        assertFalse("Must not read inside mdat", text.contains("platform=\"fake\"") || text.contains("fake"))
        val exp = JSONObject(File(dir, "mp4-mdat-uuid-noise.mp4.expected.json").readText())
        assertTrue(text.contains(exp.getString("assetId")))
    }
}
