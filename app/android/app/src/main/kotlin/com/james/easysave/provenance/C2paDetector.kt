package com.james.easysave.provenance

import java.io.File
import java.nio.charset.StandardCharsets

/**
 * Pure JVM C2PA / JUMBF content credentials detector matching provenance_dart behavior.
 * Detects:
 * - JPEG: APP11 (0xFF 0xEB) JUMBF/C2PA marker segment
 * - PNG: `caBX` chunk
 * - WebP: `C2PA` or `JUMB` RIFF chunk
 * - MP4: `jumb` box or `uuid` box with JUMBF UUID (d8fec3d6-1b0e-483c-9297-5828877ec481)
 */
object C2paDetector {

    private val JUMBF_UUID = byteArrayOf(
        0xd8.toByte(), 0xfe.toByte(), 0xc3.toByte(), 0xd6.toByte(),
        0x1b, 0x0e, 0x48, 0x3c,
        0x92.toByte(), 0x97.toByte(), 0x58, 0x28,
        0x87.toByte(), 0x7e.toByte(), 0xc4.toByte(), 0x81.toByte()
    )

    fun hasC2pa(file: File): Boolean {
        if (!file.exists() || file.length() < 12) return false
        return try {
            RafSeekableInput(file).use { hasC2pa(it) }
        } catch (_: Throwable) {
            false
        }
    }

    fun hasC2pa(input: SeekableInput): Boolean {
        return when (ProvenanceEmbedder.detectFormat(input)) {
            ProvenanceEmbedder.MediaFormat.JPEG -> hasJpegC2pa(input)
            ProvenanceEmbedder.MediaFormat.PNG -> hasPngC2pa(input)
            ProvenanceEmbedder.MediaFormat.WEBP -> hasWebpC2pa(input)
            ProvenanceEmbedder.MediaFormat.MP4 -> hasMp4C2pa(input)
            ProvenanceEmbedder.MediaFormat.UNSUPPORTED -> false
        }
    }

    private fun hasJpegC2pa(input: SeekableInput): Boolean {
        val segments = JpegProvenanceWriter.scanSegments(input)
        return segments.any { it.marker == 0xEB }
    }

    private fun hasPngC2pa(input: SeekableInput): Boolean {
        var pos = 8L
        val header = ByteArray(8)
        while (pos + 8 <= input.length) {
            input.seek(pos)
            input.readFully(header, 0, 8)
            val len = ((header[0].toInt() and 0xFF) shl 24) or
                ((header[1].toInt() and 0xFF) shl 16) or
                ((header[2].toInt() and 0xFF) shl 8) or
                (header[3].toInt() and 0xFF)
            val type = String(header, 4, 4, StandardCharsets.US_ASCII)
            if (type == "caBX") return true
            if (type == "IEND") break
            val nextPos = pos + 8L + len.toLong() + 4L
            if (nextPos > input.length || len < 0) break
            pos = nextPos
        }
        return false
    }

    private fun hasWebpC2pa(input: SeekableInput): Boolean {
        if (input.length < 12) return false
        var pos = 12L
        val header = ByteArray(8)
        while (pos + 8 <= input.length) {
            input.seek(pos)
            input.readFully(header, 0, 8)
            val type = String(header, 0, 4, StandardCharsets.US_ASCII)
            if (type == "C2PA" || type == "JUMB") return true
            val size = (header[4].toInt() and 0xFF) or
                ((header[5].toInt() and 0xFF) shl 8) or
                ((header[6].toInt() and 0xFF) shl 16) or
                ((header[7].toInt() and 0xFF) shl 24)
            val padded = size.toLong() + (size.toLong() and 1L)
            val nextPos = pos + 8L + padded
            if (nextPos > input.length || size < 0) break
            pos = nextPos
        }
        return false
    }

    private fun hasMp4C2pa(input: SeekableInput): Boolean {
        return scanMp4BoxesForC2pa(input, 0L, input.length)
    }

    private fun scanMp4BoxesForC2pa(input: SeekableInput, start: Long, end: Long): Boolean {
        var pos = start
        val header = ByteArray(8)
        val extSizeBuf = ByteArray(8)
        val uuidBuf = ByteArray(16)
        while (pos + 8 <= end) {
            input.seek(pos)
            input.readFully(header, 0, 8)
            val size32 = ((header[0].toLong() and 0xFF) shl 24) or
                ((header[1].toLong() and 0xFF) shl 16) or
                ((header[2].toLong() and 0xFF) shl 8) or
                (header[3].toLong() and 0xFF)
            val type = String(header, 4, 4, StandardCharsets.US_ASCII)
            var headerLen = 8L
            val boxSize = when (size32) {
                0L -> end - pos
                1L -> {
                    if (pos + 16 > end) break
                    input.readFully(extSizeBuf, 0, 8)
                    headerLen = 16L
                    var s = 0L
                    for (i in 0 until 8) s = (s shl 8) or (extSizeBuf[i].toLong() and 0xFF)
                    s
                }
                else -> size32
            }
            if (boxSize < headerLen || pos + boxSize > end) break
            if (type == "jumb") return true
            if (type == "uuid" && boxSize >= headerLen + 16) {
                input.readFully(uuidBuf, 0, 16)
                if (uuidBuf.contentEquals(JUMBF_UUID)) return true
            }
            if (type == "moov" || type == "meta") {
                val childStart = pos + headerLen + if (type == "meta") 4L else 0L
                if (childStart < pos + boxSize && scanMp4BoxesForC2pa(input, childStart, pos + boxSize)) {
                    return true
                }
            }
            pos += boxSize
        }
        return false
    }
}

