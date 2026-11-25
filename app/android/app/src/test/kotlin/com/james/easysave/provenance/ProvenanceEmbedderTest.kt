package com.james.easysave.provenance

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

class ProvenanceEmbedderTest {

    private fun findGoldenRoot(): File {
        val candidates = listOf(
            File("../../../../../spec/fixtures/provenance_golden"),
            File("../../../../spec/fixtures/provenance_golden"),
            File("../../../spec/fixtures/provenance_golden"),
            File("../../spec/fixtures/provenance_golden"),
            File("../spec/fixtures/provenance_golden"),
            File("spec/fixtures/provenance_golden"),
        )
        return candidates.firstOrNull { it.exists() }
            ?: fail("Golden root not found. Checked: ${candidates.map { it.canonicalPath }}") as Nothing
    }

    private fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            var n: Int
            while (input.read(buf).also { n = it } != -1) {
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun parseRecord(jsonFile: File): ProvenanceRecord {
        val json = JSONObject(jsonFile.readText())
        val creatorsList = if (json.has("creator")) {
            val arr = json.getJSONArray("creator")
            List(arr.length()) { arr.getString(it) }
        } else null
        val subjectList = if (json.has("subject")) {
            val arr = json.getJSONArray("subject")
            List(arr.length()) { arr.getString(it) }
        } else null

        return ProvenanceRecord(
            schema = json.optString("schema", "0.1"),
            assetId = json.getString("assetId"),
            capturedAt = json.getString("capturedAt"),
            capturedBy = json.getString("capturedBy"),
            metadataDate = json.getString("metadataDate"),
            sourceUrl = json.optString("sourceUrl").ifEmpty { null },
            platform = json.optString("platform").ifEmpty { null },
            sourceId = json.optString("sourceId").ifEmpty { null },
            itemIndex = if (json.has("itemIndex")) json.getInt("itemIndex") else null,
            itemCount = if (json.has("itemCount")) json.getInt("itemCount") else null,
            authorId = json.optString("authorId").ifEmpty { null },
            publishedAt = json.optString("publishedAt").ifEmpty { null },
            pairId = json.optString("pairId").ifEmpty { null },
            title = json.optString("title").ifEmpty { null },
            creator = creatorsList,
            description = json.optString("description").ifEmpty { null },
            subject = subjectList,
            credit = json.optString("credit").ifEmpty { null },
            aiLabel = json.optString("aiLabel").ifEmpty { null },
            aiLabelSource = json.optString("aiLabelSource").ifEmpty { null },
            digitalSourceType = json.optString("digitalSourceType").ifEmpty { null },
        )
    }

    @Test
    fun testByteForByteConsistencyWithGoldenOutputs() {
        val goldenRoot = findGoldenRoot()
        assertTrue("Golden root must exist at ${goldenRoot.absolutePath}", goldenRoot.exists())
        val subdirs = goldenRoot.listFiles()?.filter { it.isDirectory }?.sortedBy { it.name } ?: emptyList()
        assertTrue("Must have at least 12 golden samples", subdirs.size >= 12)

        val tempDir = File.createTempFile("provenance_test_", "").apply {
            delete()
            mkdirs()
        }

        try {
            for (dir in subdirs) {
                val inputFile = dir.listFiles()?.firstOrNull { it.name.startsWith("input.") }
                    ?: fail("Missing input file in ${dir.name}") as Nothing
                val goldenOutputFile = dir.listFiles()?.firstOrNull { it.name.startsWith("golden_output.") }
                    ?: fail("Missing golden output file in ${dir.name}") as Nothing
                val jsonFile = File(dir, "provenance.json")
                assertTrue("Missing provenance.json in ${dir.name}", jsonFile.exists())

                val record = parseRecord(jsonFile)
                val testOutput = File(tempDir, "${dir.name}_output.${inputFile.extension}")

                ProvenanceEmbedder.embed(inputFile, testOutput, record)

                val goldenSha = sha256(goldenOutputFile)
                val testSha = sha256(testOutput)

                if (goldenSha != testSha) {
                    println("Mismatch in sample: ${dir.name}")
                    println("Golden size: ${goldenOutputFile.length()}, Test size: ${testOutput.length()}")
                }

                assertEquals("Byte-for-byte SHA-256 match for ${dir.name}", goldenSha, testSha)
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun testUnsupportedContainersRefuseEmbedding() {
        val tempDir = File.createTempFile("unsupported_test_", "").apply {
            delete()
            mkdirs()
        }
        try {
            val record = ProvenanceRecord(
                assetId = "test_asset",
                capturedAt = "2026-11-23T12:00:00Z",
                capturedBy = "EasySave/1.13.0",
                metadataDate = "2026-11-23T12:00:00Z",
            )
            for (ext in listOf("heic", "heif", "avif", "gif", "txt")) {
                val dummy = File(tempDir, "sample.$ext").apply { writeBytes(ByteArray(20)) }
                val out = File(tempDir, "sample_out.$ext")
                try {
                    ProvenanceEmbedder.embed(dummy, out, record)
                    fail("Expected UnsupportedOperationException for .$ext")
                } catch (e: UnsupportedOperationException) {
                    assertTrue(e.message?.contains("skipped by design") == true)
                }
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun testLargeMp4SyntheticBenchmark() {
        // Create 700MB synthetic MP4: ftyp (32B) + moov (1665B) + free (8B) + mdat (700MB - 1705B)
        val tempDir = File.createTempFile("benchmark_700mb_", "").apply {
            delete()
            mkdirs()
        }
        val targetSize = 700L * 1024L * 1024L // 700MB
        val inputFile = File(tempDir, "input_700mb.mp4")
        val outputFile = File(tempDir, "output_700mb.mp4")

        try {
            // Write synthetic MP4 using RandomAccessFile sparse/fast seek
            val sampleInput = File(findGoldenRoot(), "mp4_1_no_xmp/input.mp4")
            assertTrue("mp4_1_no_xmp/input.mp4 must exist", sampleInput.exists())
            val headerBytes = sampleInput.readBytes().copyOf(1705) // ftyp + moov + free

            RandomAccessFile(inputFile, "rw").use { raf ->
                raf.write(headerBytes)
                // Write mdat header with declared size extending to 700MB
                val mdatSize = targetSize - 1705L
                val mdatHeader = ByteArray(8)
                mdatHeader[0] = ((mdatSize shr 24) and 0xFF).toByte()
                mdatHeader[1] = ((mdatSize shr 16) and 0xFF).toByte()
                mdatHeader[2] = ((mdatSize shr 8) and 0xFF).toByte()
                mdatHeader[3] = (mdatSize and 0xFF).toByte()
                mdatHeader[4] = 'm'.code.toByte()
                mdatHeader[5] = 'd'.code.toByte()
                mdatHeader[6] = 'a'.code.toByte()
                mdatHeader[7] = 't'.code.toByte()
                raf.write(mdatHeader)
                raf.setLength(targetSize)
            }

            assertEquals(targetSize, inputFile.length())

            val record = ProvenanceRecord(
                assetId = "benchmark_700mb_asset",
                capturedAt = "2026-11-23T12:00:00Z",
                capturedBy = "EasySave/1.13.0",
                metadataDate = "2026-11-23T12:00:00Z",
                sourceUrl = "https://example.com/video/700mb",
                platform = "bilibili"
            )

            System.gc()
            val memBefore = Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory()
            val t0 = System.currentTimeMillis()

            ProvenanceEmbedder.embed(inputFile, outputFile, record)

            val elapsedMs = System.currentTimeMillis() - t0
            val memAfter = Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory()
            val heapDeltaMb = (memAfter - memBefore) / (1024 * 1024)

            println("[BENCHMARK] 700MB MP4 embed duration: ${elapsedMs} ms, heap delta: ${heapDeltaMb} MB, output size: ${outputFile.length()}")
            assertTrue("Output file must be larger than target size", outputFile.length() > targetSize)
            assertTrue("Elapsed time should be reasonable for 700MB streaming copy", elapsedMs < 30000)
        } finally {
            tempDir.deleteRecursively()
        }
    }
}
