package com.james.easysave.provenance

import java.io.File
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets
import java.util.zip.CRC32

/**
 * Pure JVM streaming PNG provenance writer, replicating xmp_png.dart.
 */
object PngProvenanceWriter {
    const val PNG_XMP_KEYWORD = "XML:com.adobe.xmp"
    private val PNG_SIGNATURE = byteArrayOf(
        0x89.toByte(), 0x50.toByte(), 0x4E.toByte(), 0x47.toByte(),
        0x0D.toByte(), 0x0A.toByte(), 0x1A.toByte(), 0x0A.toByte()
    )

    class PngChunk(
        val type: String,
        val start: Long,
        val stop: Long,
        val dataStart: Long,
        val dataStop: Long,
    )

    fun scanChunks(input: SeekableInput): List<PngChunk> {
        val length = input.length
        input.seek(0)
        val sig = ByteArray(8)
        if (input.read(sig, 0, 8) < 8 || !sig.contentEquals(PNG_SIGNATURE)) {
            throw IllegalArgumentException("Not a PNG file")
        }

        val chunks = mutableListOf<PngChunk>()
        var offset = 8L
        val head = ByteArray(8)

        while (offset + 12 <= length) {
            input.seek(offset)
            input.readFully(head)
            val dataLen = (((head[0].toInt() and 0xFF).toLong() shl 24) or
                    ((head[1].toInt() and 0xFF).toLong() shl 16) or
                    ((head[2].toInt() and 0xFF).toLong() shl 8) or
                    ((head[3].toInt() and 0xFF).toLong()))
            val type = String(head, 4, 4, StandardCharsets.US_ASCII)
            val stop = offset + 12 + dataLen
            if (stop > length) break

            chunks.add(PngChunk(type, offset, stop, offset + 8, offset + 8 + dataLen))
            offset = stop
            if (type == "IEND") break
        }
        return chunks
    }

    fun scanChunks(file: RandomAccessFile): List<PngChunk> = scanChunks(RafSeekableInput(file))

    private fun encodeChunk(type: String, data: ByteArray): ByteArray {
        val typeBytes = type.toByteArray(StandardCharsets.US_ASCII)
        val crc = CRC32()
        crc.update(typeBytes)
        crc.update(data)
        val crcVal = crc.value

        val chunk = ByteArray(12 + data.size)
        chunk[0] = ((data.size ushr 24) and 0xFF).toByte()
        chunk[1] = ((data.size ushr 16) and 0xFF).toByte()
        chunk[2] = ((data.size ushr 8) and 0xFF).toByte()
        chunk[3] = (data.size and 0xFF).toByte()
        System.arraycopy(typeBytes, 0, chunk, 4, 4)
        System.arraycopy(data, 0, chunk, 8, data.size)
        val crcOffset = 8 + data.size
        chunk[crcOffset] = ((crcVal ushr 24) and 0xFF).toByte()
        chunk[crcOffset + 1] = ((crcVal ushr 16) and 0xFF).toByte()
        chunk[crcOffset + 2] = ((crcVal ushr 8) and 0xFF).toByte()
        chunk[crcOffset + 3] = (crcVal and 0xFF).toByte()
        return chunk
    }

    fun embedToStream(input: File, outputStream: OutputStream, record: ProvenanceRecord): StreamingFileRewriter.WriteResult {
        val inRaf = RandomAccessFile(input, "r")
        val chunks: List<PngChunk>
        var existing: PngChunk? = null
        var currentXml: String? = null

        try {
            chunks = scanChunks(inRaf)
            for (chunk in chunks) {
                if (chunk.type == "iTXt") {
                    val dLen = (chunk.dataStop - chunk.dataStart).toInt()
                    if (dLen >= PNG_XMP_KEYWORD.length + 5) {
                        inRaf.seek(chunk.dataStart)
                        val data = ByteArray(dLen)
                        inRaf.readFully(data)
                        val kwBytes = PNG_XMP_KEYWORD.toByteArray(StandardCharsets.UTF_8)
                        var match = true
                        for (i in kwBytes.indices) {
                            if (data[i] != kwBytes[i]) { match = false; break }
                        }
                        if (match && data[kwBytes.size] == 0.toByte()) {
                            val textStart = kwBytes.size + 5
                            if (data[kwBytes.size + 1] == 0.toByte()) {
                                existing = chunk
                                currentXml = String(data, textStart, dLen - textStart, StandardCharsets.UTF_8)
                                break
                            }
                        }
                    }
                }
            }
        } finally {
            inRaf.close()
        }

        val targetXml = if (currentXml == null) XmpCore.buildXmpXml(record) else XmpCore.updateXmpXml(currentXml, record)
        val xmlBytes = targetXml.toByteArray(StandardCharsets.UTF_8)
        val kwBytes = PNG_XMP_KEYWORD.toByteArray(StandardCharsets.UTF_8)
        val chunkData = ByteArray(kwBytes.size + 5 + xmlBytes.size)
        System.arraycopy(kwBytes, 0, chunkData, 0, kwBytes.size)
        chunkData[kwBytes.size] = 0
        chunkData[kwBytes.size + 1] = 0
        chunkData[kwBytes.size + 2] = 0
        chunkData[kwBytes.size + 3] = 0
        chunkData[kwBytes.size + 4] = 0
        System.arraycopy(xmlBytes, 0, chunkData, kwBytes.size + 5, xmlBytes.size)

        val chunkBytes = encodeChunk("iTXt", chunkData)

        val replaceStart: Long
        val replaceStop: Long
        if (existing != null) {
            replaceStart = existing.start
            replaceStop = existing.stop
        } else {
            var insertAt = if (chunks.isEmpty()) 8L else chunks.last().stop
            for (c in chunks) {
                if (c.type == "IEND") {
                    insertAt = c.start
                    break
                }
            }
            replaceStart = insertAt
            replaceStop = insertAt
        }

        return StreamingFileRewriter.rewriteToStream(
            input = input,
            outStream = outputStream,
            regions = listOf(StreamingFileRewriter.ReplacementRegion(replaceStart, replaceStop, chunkBytes))
        )
    }

    fun embed(input: File, output: File, record: ProvenanceRecord) {
        output.outputStream().use { embedToStream(input, it, record) }
    }
}
