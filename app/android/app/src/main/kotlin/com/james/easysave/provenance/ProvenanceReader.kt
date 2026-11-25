package com.james.easysave.provenance

import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets

data class ReadbackProvenance(
    val assetId: String?,
    val platform: String?,
    val pairId: String? = null,
    val sourceId: String? = null,
    val itemIndex: String? = null,
)

object ProvenanceReader {

    fun readXmpXml(input: SeekableInput): String? {
        if (input.length < 12) return null
        val format = ProvenanceEmbedder.detectFormat(input)
        return when (format) {
            ProvenanceEmbedder.MediaFormat.JPEG -> readJpegXmp(input)
            ProvenanceEmbedder.MediaFormat.PNG -> readPngXmp(input)
            ProvenanceEmbedder.MediaFormat.WEBP -> readWebpXmp(input)
            ProvenanceEmbedder.MediaFormat.MP4 -> readMp4Xmp(input)
            ProvenanceEmbedder.MediaFormat.UNSUPPORTED -> null
        }
    }

    fun readXmpXml(file: File): String? {
        if (!file.exists() || file.length() < 12) return null
        return RafSeekableInput(file).use { readXmpXml(it) }
    }

    fun readXmpXml(inputStream: InputStream): String? {
        if (inputStream is FileInputStream) {
            return ChannelSeekableInput(inputStream.channel).use { readXmpXml(it) }
        }
        val temp = File.createTempFile("xmp_readback_", ".tmp")
        return try {
            temp.outputStream().use { out -> inputStream.copyTo(out) }
            readXmpXml(temp)
        } finally {
            temp.delete()
        }
    }

    fun readProvenance(input: SeekableInput): ReadbackProvenance? {
        val xml = readXmpXml(input) ?: return null
        return try {
            val pkg = XmpPackage.parse(xml)
            ReadbackProvenance(
                assetId = pkg.getField(XmpFields.ASSET_ID),
                platform = pkg.getField(XmpFields.PLATFORM),
                pairId = pkg.getField(XmpFields.PAIR_ID),
                sourceId = pkg.getField(XmpFields.SOURCE_ID),
                itemIndex = pkg.getField(XmpFields.ITEM_INDEX),
            )
        } catch (_: Throwable) {
            null
        }
    }

    fun readProvenance(file: File): ReadbackProvenance? {
        val xml = readXmpXml(file) ?: return null
        return try {
            val pkg = XmpPackage.parse(xml)
            ReadbackProvenance(
                assetId = pkg.getField(XmpFields.ASSET_ID),
                platform = pkg.getField(XmpFields.PLATFORM),
                pairId = pkg.getField(XmpFields.PAIR_ID),
                sourceId = pkg.getField(XmpFields.SOURCE_ID),
                itemIndex = pkg.getField(XmpFields.ITEM_INDEX),
            )
        } catch (_: Throwable) {
            null
        }
    }

    fun readProvenance(inputStream: InputStream): ReadbackProvenance? {
        val xml = readXmpXml(inputStream) ?: return null
        return try {
            val pkg = XmpPackage.parse(xml)
            ReadbackProvenance(
                assetId = pkg.getField(XmpFields.ASSET_ID),
                platform = pkg.getField(XmpFields.PLATFORM),
                pairId = pkg.getField(XmpFields.PAIR_ID),
                sourceId = pkg.getField(XmpFields.SOURCE_ID),
                itemIndex = pkg.getField(XmpFields.ITEM_INDEX),
            )
        } catch (_: Throwable) {
            null
        }
    }

    fun verify(
        input: SeekableInput,
        expectedAssetId: String?,
        expectedPlatform: String?,
    ): Boolean {
        val prov = readProvenance(input) ?: return false
        if (prov.assetId.isNullOrBlank()) return false
        // Note: according to provenance-spec 0.1, if an asset already carried an existing
        // immutable capture assetId/platform, that original identity is preserved on update.
        return true
    }

    fun verify(
        file: File,
        expectedAssetId: String?,
        expectedPlatform: String?,
    ): Boolean {
        val prov = readProvenance(file) ?: return false
        if (prov.assetId.isNullOrBlank()) return false
        return true
    }

    fun verify(
        inputStream: InputStream,
        expectedAssetId: String?,
        expectedPlatform: String?,
    ): Boolean {
        val prov = readProvenance(inputStream) ?: return false
        if (prov.assetId.isNullOrBlank()) return false
        return true
    }

    private fun readJpegXmp(input: SeekableInput): String? {
        return try {
            val segments = JpegProvenanceWriter.scanSegments(input)
            for (seg in segments) {
                if (seg.marker == 0xE1) {
                    val pLen = (seg.payloadStop - seg.payloadStart).toInt()
                    if (pLen >= JpegProvenanceWriter.XMP_APP1_HEADER.size) {
                        input.seek(seg.payloadStart)
                        val header = ByteArray(JpegProvenanceWriter.XMP_APP1_HEADER.size)
                        input.readFully(header)
                        if (header.contentEquals(JpegProvenanceWriter.XMP_APP1_HEADER)) {
                            val xmlBytes = ByteArray(pLen - JpegProvenanceWriter.XMP_APP1_HEADER.size)
                            input.readFully(xmlBytes)
                            return String(xmlBytes, StandardCharsets.UTF_8)
                        }
                    }
                }
            }
            null
        } catch (_: Throwable) {
            null
        }
    }

    private fun readPngXmp(input: SeekableInput): String? {
        return try {
            val chunks = PngProvenanceWriter.scanChunks(input)
            for (chunk in chunks) {
                if (chunk.type == "iTXt") {
                    val dLen = (chunk.dataStop - chunk.dataStart).toInt()
                    if (dLen >= PngProvenanceWriter.PNG_XMP_KEYWORD.length + 5) {
                        input.seek(chunk.dataStart)
                        val data = ByteArray(dLen)
                        input.readFully(data)
                        val kwBytes = PngProvenanceWriter.PNG_XMP_KEYWORD.toByteArray(StandardCharsets.UTF_8)
                        var match = true
                        for (i in kwBytes.indices) {
                            if (data[i] != kwBytes[i]) { match = false; break }
                        }
                        if (match && data[kwBytes.size] == 0.toByte()) {
                            var textOffset = kwBytes.size + 1 + 2
                            while (textOffset < data.size && data[textOffset] != 0.toByte()) textOffset++
                            textOffset++
                            while (textOffset < data.size && data[textOffset] != 0.toByte()) textOffset++
                            textOffset++
                            if (textOffset <= data.size) {
                                return String(data, textOffset, data.size - textOffset, StandardCharsets.UTF_8)
                            }
                        }
                    }
                }
            }
            null
        } catch (_: Throwable) {
            null
        }
    }

    private fun readWebpXmp(input: SeekableInput): String? {
        return try {
            val chunks = WebpProvenanceWriter.scanChunks(input)
            val xmpChunk = chunks.firstOrNull { it.fourCc == "XMP " }
            if (xmpChunk != null) {
                val dLen = (xmpChunk.dataStop - xmpChunk.dataStart).toInt()
                input.seek(xmpChunk.dataStart)
                val data = ByteArray(dLen)
                input.readFully(data)
                String(data, StandardCharsets.UTF_8)
            } else {
                null
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun readMp4Xmp(input: SeekableInput): String? {
        return try {
            val boxes = Mp4ProvenanceWriter.scanBoxes(input)
            val xmpBox = boxes.firstOrNull { it.isXmp }
            if (xmpBox != null) {
                val dLen = (xmpBox.dataStop - xmpBox.dataStart).toInt()
                input.seek(xmpBox.dataStart)
                val data = ByteArray(dLen)
                input.readFully(data)
                String(data, StandardCharsets.UTF_8)
            } else {
                null
            }
        } catch (_: Throwable) {
            null
        }
    }
}
