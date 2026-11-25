package com.james.easysave.provenance

import java.io.File
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets

/**
 * Pure JVM streaming JPEG provenance writer, replicating xmp_jpeg.dart.
 */
object JpegProvenanceWriter {
    val XMP_APP1_HEADER = "http://ns.adobe.com/xap/1.0/\u0000".toByteArray(StandardCharsets.UTF_8)
    private const val MAX_JPEG_XMP_BYTES = 60 * 1024

    class JpegSegment(
        val marker: Int,
        val start: Long,
        val stop: Long,
        val payloadStart: Long,
        val payloadStop: Long,
    )

    fun scanSegments(input: SeekableInput): List<JpegSegment> {
        val length = input.length
        input.seek(0)
        val soi = ByteArray(2)
        if (input.read(soi, 0, 2) < 2 || (soi[0].toInt() and 0xFF) != 0xFF || (soi[1].toInt() and 0xFF) != 0xD8) {
            throw IllegalArgumentException("Not a JPEG file")
        }

        val segments = mutableListOf<JpegSegment>()
        var offset = 2L

        val head = ByteArray(4)
        while (offset + 1 < length) {
            input.seek(offset)
            val read = input.read(head, 0, 4)
            if (read < 2) break
            if ((head[0].toInt() and 0xFF) != 0xFF) break
            val marker = head[1].toInt() and 0xFF

            if (marker == 0xD9 || marker == 0xDA) break

            if (marker == 0x01 || (marker in 0xD0..0xD7)) {
                segments.add(JpegSegment(marker, offset, offset + 2, offset + 2, offset + 2))
                offset += 2
                continue
            }

            if (read < 4) break
            val segmentLength = ((head[2].toInt() and 0xFF) shl 8) or (head[3].toInt() and 0xFF)
            if (segmentLength < 2) break
            val stop = offset + 2 + segmentLength
            if (stop > length) break

            segments.add(JpegSegment(marker, offset, stop, offset + 4, stop))
            offset = stop
        }
        return segments
    }

    fun scanSegments(file: RandomAccessFile): List<JpegSegment> = scanSegments(RafSeekableInput(file))

    fun embedToStream(input: File, outputStream: OutputStream, record: ProvenanceRecord): StreamingFileRewriter.WriteResult {
        val inRaf = RandomAccessFile(input, "r")
        val segments: List<JpegSegment>
        var existing: JpegSegment? = null
        var currentXml: String? = null

        try {
            segments = scanSegments(inRaf)
            for (seg in segments) {
                if (seg.marker == 0xE1) {
                    val pLen = (seg.payloadStop - seg.payloadStart).toInt()
                    if (pLen >= XMP_APP1_HEADER.size) {
                        inRaf.seek(seg.payloadStart)
                        val header = ByteArray(XMP_APP1_HEADER.size)
                        inRaf.readFully(header)
                        if (header.contentEquals(XMP_APP1_HEADER)) {
                            existing = seg
                            val xmlBytes = ByteArray(pLen - XMP_APP1_HEADER.size)
                            inRaf.readFully(xmlBytes)
                            currentXml = String(xmlBytes, StandardCharsets.UTF_8)
                            break
                        }
                    }
                }
            }
        } finally {
            inRaf.close()
        }

        val targetXml = if (currentXml == null) XmpCore.buildXmpXml(record) else XmpCore.updateXmpXml(currentXml, record)
        val xmlBytes = targetXml.toByteArray(StandardCharsets.UTF_8)
        if (xmlBytes.size >= MAX_JPEG_XMP_BYTES) {
            throw IllegalArgumentException("XMP package must stay below 60 KB for a JPEG APP1 segment")
        }

        val totalLen = 2 + XMP_APP1_HEADER.size + xmlBytes.size
        val segmentBytes = ByteArray(2 + totalLen)
        segmentBytes[0] = 0xFF.toByte()
        segmentBytes[1] = 0xE1.toByte()
        segmentBytes[2] = ((totalLen shr 8) and 0xFF).toByte()
        segmentBytes[3] = (totalLen and 0xFF).toByte()
        System.arraycopy(XMP_APP1_HEADER, 0, segmentBytes, 4, XMP_APP1_HEADER.size)
        System.arraycopy(xmlBytes, 0, segmentBytes, 4 + XMP_APP1_HEADER.size, xmlBytes.size)

        val replaceStart: Long
        val replaceStop: Long
        if (existing != null) {
            replaceStart = existing.start
            replaceStop = existing.stop
        } else {
            var insertAt = 2L
            for (candidate in segments) {
                if (candidate.marker in 0xE0..0xEF) {
                    insertAt = candidate.stop
                }
            }
            replaceStart = insertAt
            replaceStop = insertAt
        }

        return StreamingFileRewriter.rewriteToStream(
            input = input,
            outStream = outputStream,
            regions = listOf(StreamingFileRewriter.ReplacementRegion(replaceStart, replaceStop, segmentBytes))
        )
    }

    fun embed(input: File, output: File, record: ProvenanceRecord) {
        output.outputStream().use { embedToStream(input, it, record) }
    }
}
