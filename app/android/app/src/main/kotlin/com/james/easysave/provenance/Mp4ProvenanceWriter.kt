package com.james.easysave.provenance

import java.io.File
import java.io.RandomAccessFile
import java.io.OutputStream
import java.nio.charset.StandardCharsets

/**
 * Pure JVM streaming MP4 provenance writer, replicating xmp_mp4.dart.
 */
object Mp4ProvenanceWriter {
    val MP4_XMP_UUID = byteArrayOf(
        0xBE.toByte(), 0x7A.toByte(), 0xCF.toByte(), 0xCB.toByte(),
        0x97.toByte(), 0xA9.toByte(), 0x42.toByte(), 0xE8.toByte(),
        0x9C.toByte(), 0x71.toByte(), 0x99.toByte(), 0x94.toByte(),
        0x91.toByte(), 0xE3.toByte(), 0xAF.toByte(), 0xAC.toByte()
    )
    val FREE_BYTES = "free".toByteArray(StandardCharsets.US_ASCII)
    private val UUID_TYPE_BYTES = "uuid".toByteArray(StandardCharsets.US_ASCII)
    private const val MAX_MP4_XMP_BYTES = 50 * 1024 * 1024

    private val KNOWN_TOP_LEVEL_TYPES = setOf(
        "ftyp", "moov", "mdat", "free", "skip", "wide", "junk", "pnot", "uuid"
    )

    class Mp4Box(
        val type: String,
        val typeOffset: Long,
        val start: Long,
        val stop: Long,
        val headerSize: Int,
        val dataStart: Long,
        val dataStop: Long,
        val declaredSize: Long,
        val isExtendsToEnd: Boolean,
        val isTruncated: Boolean,
        val uuid: ByteArray?,
    ) {
        val isXmp: Boolean
            get() = type == "uuid" && uuid != null && uuid.contentEquals(MP4_XMP_UUID)
    }

    fun scanBoxes(input: SeekableInput): List<Mp4Box> {
        val length = input.length
        val boxes = mutableListOf<Mp4Box>()
        var offset = 0L
        val head = ByteArray(32)

        while (offset + 8 <= length) {
            input.seek(offset)
            val read = input.read(head, 0, 32)
            if (read < 8) break

            val size = ((head[0].toInt() and 0xFF).toLong() shl 24) or
                    ((head[1].toInt() and 0xFF).toLong() shl 16) or
                    ((head[2].toInt() and 0xFF).toLong() shl 8) or
                    ((head[3].toInt() and 0xFF).toLong())
            val type = String(head, 4, 4, StandardCharsets.US_ASCII)
            val typeOffset = offset + 4

            var headerSize = 8
            var isExtendsToEnd = false
            val declaredSize: Long

            if (size == 1L) {
                if (offset + 16 > length) break
                val largeSize = if (read >= 16) {
                    readU64(head, 8)
                } else {
                    input.seek(offset + 8)
                    val ext = ByteArray(8)
                    input.readFully(ext)
                    readU64(ext, 0)
                }
                if (largeSize < 16L) break
                headerSize = 16
                declaredSize = largeSize
            } else if (size == 0L) {
                isExtendsToEnd = true
                declaredSize = length - offset
            } else if (size < 8L) {
                break
            } else {
                declaredSize = size
            }

            val end = offset + declaredSize
            val truncated = end > length
            val stop = if (truncated) length else end
            val dataStart = offset + headerSize
            val dataStop = if (truncated) length else end

            var uuid: ByteArray? = null
            if (type == "uuid" && dataStart + 16 <= stop) {
                uuid = ByteArray(16)
                if (read >= headerSize + 16) {
                    System.arraycopy(head, headerSize, uuid, 0, 16)
                } else {
                    input.seek(dataStart)
                    input.readFully(uuid)
                }
            }

            boxes.add(
                Mp4Box(
                    type = type,
                    typeOffset = typeOffset,
                    start = offset,
                    stop = stop,
                    headerSize = headerSize,
                    dataStart = dataStart,
                    dataStop = dataStop,
                    declaredSize = declaredSize,
                    isExtendsToEnd = isExtendsToEnd,
                    isTruncated = truncated,
                    uuid = uuid,
                )
            )
            offset = stop
        }
        return boxes
    }

    fun scanBoxes(file: RandomAccessFile): List<Mp4Box> = scanBoxes(RafSeekableInput(file))

    private fun readU64(b: ByteArray, offset: Int): Long {
        return (((b[offset].toInt() and 0xFF).toLong() shl 56) or
                ((b[offset + 1].toInt() and 0xFF).toLong() shl 48) or
                ((b[offset + 2].toInt() and 0xFF).toLong() shl 40) or
                ((b[offset + 3].toInt() and 0xFF).toLong() shl 32) or
                ((b[offset + 4].toInt() and 0xFF).toLong() shl 24) or
                ((b[offset + 5].toInt() and 0xFF).toLong() shl 16) or
                ((b[offset + 6].toInt() and 0xFF).toLong() shl 8) or
                ((b[offset + 7].toInt() and 0xFF).toLong()))
    }

    private fun encodeXmpBox(xml: String): ByteArray {
        val payload = xml.toByteArray(StandardCharsets.UTF_8)
        val total32 = 8L + MP4_XMP_UUID.size + payload.size
        if (total32 <= 0xFFFFFFFFL) {
            val box = ByteArray(total32.toInt())
            box[0] = ((total32 shr 24) and 0xFF).toByte()
            box[1] = ((total32 shr 16) and 0xFF).toByte()
            box[2] = ((total32 shr 8) and 0xFF).toByte()
            box[3] = (total32 and 0xFF).toByte()
            System.arraycopy(UUID_TYPE_BYTES, 0, box, 4, 4)
            System.arraycopy(MP4_XMP_UUID, 0, box, 8, MP4_XMP_UUID.size)
            System.arraycopy(payload, 0, box, 8 + MP4_XMP_UUID.size, payload.size)
            return box
        } else {
            val total64 = 16L + MP4_XMP_UUID.size + payload.size
            val box = ByteArray(total64.toInt())
            box[0] = 0; box[1] = 0; box[2] = 0; box[3] = 1
            System.arraycopy(UUID_TYPE_BYTES, 0, box, 4, 4)
            for (i in 0..7) {
                box[8 + i] = ((total64 shr ((7 - i) * 8)) and 0xFF).toByte()
            }
            System.arraycopy(MP4_XMP_UUID, 0, box, 16, MP4_XMP_UUID.size)
            System.arraycopy(payload, 0, box, 16 + MP4_XMP_UUID.size, payload.size)
            return box
        }
    }

    fun embedToStream(input: File, outputStream: OutputStream, record: ProvenanceRecord): StreamingFileRewriter.WriteResult {
        val inRaf = RandomAccessFile(input, "r")
        val length = inRaf.length()
        val boxes: List<Mp4Box>
        var currentXml: String? = null
        val oldXmpBoxes = mutableListOf<Mp4Box>()

        try {
            boxes = scanBoxes(inRaf)
            if (boxes.isEmpty() || !KNOWN_TOP_LEVEL_TYPES.contains(boxes.first().type)) {
                throw IllegalArgumentException("File does not start with an MP4 / MOV box")
            }

            for (box in boxes) {
                if (box.isXmp) {
                    oldXmpBoxes.add(box)
                    val xmpLen = (box.dataStop - box.dataStart).toInt()
                    if (xmpLen in 1..MAX_MP4_XMP_BYTES) {
                        inRaf.seek(box.dataStart)
                        val xmpBytes = ByteArray(xmpLen)
                        inRaf.readFully(xmpBytes)
                        currentXml = String(xmpBytes, StandardCharsets.UTF_8)
                    }
                }
            }
        } finally {
            inRaf.close()
        }

        val last = boxes.last()
        var truncateFrom: Long? = null
        if (last.isTruncated) {
            val available = length - last.start
            if (last.isXmp && available >= 24 && available <= MAX_MP4_XMP_BYTES) {
                truncateFrom = last.start
            } else {
                throw IllegalArgumentException("The last top-level box is incomplete and is not a recoverable XMP box")
            }
        } else if (last.stop != length) {
            throw IllegalArgumentException("The last top-level box does not end at the end of the file")
        }

        var sizeZeroBox: Mp4Box? = null
        var materializedSize: Long? = null
        if (truncateFrom == null && last.isExtendsToEnd) {
            val actual = length - last.start
            if (actual > 0xFFFFFFFFL) {
                throw IllegalArgumentException("The last box has size 0 and is larger than 4 GiB")
            }
            sizeZeroBox = last
            materializedSize = actual
        }

        val appendAt = truncateFrom ?: length
        val targetXml = if (currentXml == null) XmpCore.buildXmpXml(record) else XmpCore.updateXmpXml(currentXml, record)
        val newBoxBytes = encodeXmpBox(targetXml)

        val regions = mutableListOf<StreamingFileRewriter.ReplacementRegion>()
        if (sizeZeroBox != null) {
            val s = materializedSize!!
            val sizeBytes = byteArrayOf(
                ((s shr 24) and 0xFF).toByte(),
                ((s shr 16) and 0xFF).toByte(),
                ((s shr 8) and 0xFF).toByte(),
                (s and 0xFF).toByte(),
            )
            regions.add(StreamingFileRewriter.ReplacementRegion(sizeZeroBox.start, sizeZeroBox.start + 4, sizeBytes))
        }
        for (box in oldXmpBoxes) {
            regions.add(StreamingFileRewriter.ReplacementRegion(box.typeOffset, box.typeOffset + 4, FREE_BYTES))
        }
        regions.add(StreamingFileRewriter.ReplacementRegion(appendAt, length, newBoxBytes))

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
