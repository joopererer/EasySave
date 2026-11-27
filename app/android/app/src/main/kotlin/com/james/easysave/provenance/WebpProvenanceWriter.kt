package com.james.easysave.provenance

import java.io.File
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets

/**
 * Pure JVM streaming WebP provenance writer, replicating xmp_webp.dart.
 */
object WebpProvenanceWriter {
    const val WEBP_XMP_FOURCC = "XMP "
    const val WEBP_XMP_FLAG = 0x04

    class WebpChunk(
        val fourCc: String,
        val start: Long,
        val stop: Long,
        val dataStart: Long,
        val dataStop: Long,
    )

    fun scanChunks(input: SeekableInput): List<WebpChunk> {
        val length = input.length
        input.seek(0)
        val header = ByteArray(12)
        if (input.read(header, 0, 12) < 12) throw IllegalArgumentException("Not a WebP file")
        if (String(header, 0, 4, StandardCharsets.US_ASCII) != "RIFF" ||
            String(header, 8, 4, StandardCharsets.US_ASCII) != "WEBP"
        ) {
            throw IllegalArgumentException("Not a WebP file")
        }

        val chunks = mutableListOf<WebpChunk>()
        var offset = 12L
        val head = ByteArray(8)

        while (offset + 8 <= length) {
            input.seek(offset)
            input.readFully(head)
            val fourCc = String(head, 0, 4, StandardCharsets.US_ASCII)
            val dataLen = ((head[4].toInt() and 0xFF).toLong()) or
                    ((head[5].toInt() and 0xFF).toLong() shl 8) or
                    ((head[6].toInt() and 0xFF).toLong() shl 16) or
                    ((head[7].toInt() and 0xFF).toLong() shl 24)
            val paddedLen = if (dataLen % 2L != 0L) dataLen + 1 else dataLen
            val stop = offset + 8 + paddedLen
            if (stop > length) break

            chunks.add(WebpChunk(fourCc, offset, stop, offset + 8, offset + 8 + dataLen))
            offset = stop
        }
        return chunks
    }

    fun scanChunks(file: RandomAccessFile): List<WebpChunk> = scanChunks(RafSeekableInput(file))

    private fun readDimensions(file: RandomAccessFile, chunks: List<WebpChunk>): Pair<Int, Int> {
        val vp8 = chunks.firstOrNull { it.fourCc == "VP8 " }
        if (vp8 != null) {
            file.seek(vp8.dataStart)
            val data = ByteArray(10)
            file.readFully(data)
            val width = (data[6].toInt() and 0xFF) or ((data[7].toInt() and 0x3F) shl 8)
            val height = (data[8].toInt() and 0xFF) or ((data[9].toInt() and 0x3F) shl 8)
            return Pair(width, height)
        }

        val vp8l = chunks.firstOrNull { it.fourCc == "VP8L" }
        if (vp8l != null) {
            file.seek(vp8l.dataStart)
            val data = ByteArray(5)
            file.readFully(data)
            if (data[0] != 0x2F.toByte()) throw IllegalArgumentException("Invalid VP8L bitstream")
            val bits = (data[1].toInt() and 0xFF) or
                    ((data[2].toInt() and 0xFF) shl 8) or
                    ((data[3].toInt() and 0xFF) shl 16) or
                    ((data[4].toInt() and 0xFF) shl 24)
            val width = (bits and 0x3FFF) + 1
            val height = ((bits shr 14) and 0x3FFF) + 1
            return Pair(width, height)
        }

        throw IllegalArgumentException("WebP file has no VP8 or VP8L chunk")
    }

    private fun encodeChunk(fourCc: String, data: ByteArray): ByteArray {
        val pad = if (data.size % 2 != 0) 1 else 0
        val chunk = ByteArray(8 + data.size + pad)
        val ccBytes = fourCc.toByteArray(StandardCharsets.US_ASCII)
        System.arraycopy(ccBytes, 0, chunk, 0, 4)
        chunk[4] = (data.size and 0xFF).toByte()
        chunk[5] = ((data.size ushr 8) and 0xFF).toByte()
        chunk[6] = ((data.size ushr 16) and 0xFF).toByte()
        chunk[7] = ((data.size ushr 24) and 0xFF).toByte()
        System.arraycopy(data, 0, chunk, 8, data.size)
        if (pad != 0) chunk[chunk.size - 1] = 0
        return chunk
    }

    private fun encodeVp8x(width: Int, height: Int): ByteArray {
        val w = width - 1
        val h = height - 1
        val data = byteArrayOf(
            WEBP_XMP_FLAG.toByte(), 0, 0, 0,
            (w and 0xFF).toByte(), ((w shr 8) and 0xFF).toByte(), ((w shr 16) and 0xFF).toByte(),
            (h and 0xFF).toByte(), ((h shr 8) and 0xFF).toByte(), ((h shr 16) and 0xFF).toByte(),
        )
        return encodeChunk("VP8X", data)
    }

    fun embedToStream(input: File, outputStream: OutputStream, record: ProvenanceRecord): StreamingFileRewriter.WriteResult {
        val inRaf = RandomAccessFile(input, "r")
        val fileLength = inRaf.length()
        val chunks: List<WebpChunk>
        var existing: WebpChunk? = null
        var currentXml: String? = null
        var vp8xFlags: Int? = null
        var dimensions: Pair<Int, Int>? = null

        try {
            chunks = scanChunks(inRaf)
            existing = chunks.firstOrNull { it.fourCc == WEBP_XMP_FOURCC }
            if (existing != null) {
                val dLen = (existing.dataStop - existing.dataStart).toInt()
                inRaf.seek(existing.dataStart)
                val data = ByteArray(dLen)
                inRaf.readFully(data)
                currentXml = String(data, StandardCharsets.UTF_8)
            }

            val vp8x = chunks.firstOrNull { it.fourCc == "VP8X" }
            if (vp8x != null) {
                inRaf.seek(vp8x.dataStart)
                vp8xFlags = inRaf.read()
            } else {
                dimensions = readDimensions(inRaf, chunks)
            }
        } finally {
            inRaf.close()
        }

        val targetXml = if (currentXml == null) XmpCore.buildXmpXml(record) else XmpCore.updateXmpXml(currentXml, record)
        val xmpChunk = encodeChunk(WEBP_XMP_FOURCC, targetXml.toByteArray(StandardCharsets.UTF_8))

        val regions = mutableListOf<StreamingFileRewriter.ReplacementRegion>()
        if (existing != null) {
            regions.add(StreamingFileRewriter.ReplacementRegion(existing.start, existing.stop, xmpChunk))
        } else {
            regions.add(StreamingFileRewriter.ReplacementRegion(fileLength, fileLength, xmpChunk))
        }

        if (vp8xFlags != null) {
            val vp8x = chunks.first { it.fourCc == "VP8X" }
            val newFlagByte = byteArrayOf((vp8xFlags or WEBP_XMP_FLAG).toByte())
            regions.add(StreamingFileRewriter.ReplacementRegion(vp8x.dataStart, vp8x.dataStart + 1, newFlagByte))
        } else {
            val vp8xChunk = encodeVp8x(dimensions!!.first, dimensions.second)
            regions.add(StreamingFileRewriter.ReplacementRegion(12L, 12L, vp8xChunk))
        }

        var newLength = fileLength
        for (r in regions) {
            newLength += r.replacement.size - (r.stop - r.start)
        }
        val riffLen = newLength - 8
        val riffLenBytes = byteArrayOf(
            (riffLen and 0xFF).toByte(),
            ((riffLen shr 8) and 0xFF).toByte(),
            ((riffLen shr 16) and 0xFF).toByte(),
            ((riffLen shr 24) and 0xFF).toByte(),
        )
        regions.add(StreamingFileRewriter.ReplacementRegion(4L, 8L, riffLenBytes))

        return StreamingFileRewriter.rewriteToStream(
            input = input,
            outStream = outputStream,
            regions = regions
        )
    }

    fun embed(input: File, output: File, record: ProvenanceRecord) {
        output.outputStream().use { embedToStream(input, it, record) }
    }
}
