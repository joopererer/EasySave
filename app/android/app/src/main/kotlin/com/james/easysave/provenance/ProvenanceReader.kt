package com.james.easysave.provenance

import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets

data class ReadbackProvenance(
    val assetId: String?,
    val platform: String?,
)

object ProvenanceReader {

    fun readXmpXml(file: File): String? {
        if (!file.exists() || file.length() < 12) return null
        val format = ProvenanceEmbedder.detectFormat(file)
        return when (format) {
            ProvenanceEmbedder.MediaFormat.JPEG -> readJpegXmp(file)
            ProvenanceEmbedder.MediaFormat.PNG -> readPngXmp(file)
            ProvenanceEmbedder.MediaFormat.WEBP -> readWebpXmp(file)
            ProvenanceEmbedder.MediaFormat.MP4 -> readMp4Xmp(file)
            ProvenanceEmbedder.MediaFormat.UNSUPPORTED -> null
        }
    }

    fun readXmpXml(inputStream: InputStream): String? {
        val temp = File.createTempFile("xmp_readback_", ".tmp")
        return try {
            temp.outputStream().use { out -> inputStream.copyTo(out) }
            readXmpXml(temp)
        } finally {
            temp.delete()
        }
    }

    fun readProvenance(file: File): ReadbackProvenance? {
        val xml = readXmpXml(file) ?: return null
        return try {
            val pkg = XmpPackage.parse(xml)
            ReadbackProvenance(
                assetId = pkg.getField(XmpFields.ASSET_ID),
                platform = pkg.getField(XmpFields.PLATFORM),
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
            )
        } catch (_: Throwable) {
            null
        }
    }

    fun verify(
        file: File,
        expectedAssetId: String?,
        expectedPlatform: String?,
    ): Boolean {
        val prov = readProvenance(file) ?: return false
        if (expectedAssetId != null && prov.assetId != expectedAssetId) return false
        if (expectedPlatform != null && prov.platform != expectedPlatform) return false
        return true
    }

    fun verify(
        inputStream: InputStream,
        expectedAssetId: String?,
        expectedPlatform: String?,
    ): Boolean {
        val prov = readProvenance(inputStream) ?: return false
        if (expectedAssetId != null && prov.assetId != expectedAssetId) return false
        if (expectedPlatform != null && prov.platform != expectedPlatform) return false
        return true
    }

    private fun readJpegXmp(file: File): String? {
        val inRaf = RandomAccessFile(file, "r")
        return try {
            val segments = JpegProvenanceWriter.scanSegments(inRaf)
            for (seg in segments) {
                if (seg.marker == 0xE1) {
                    val pLen = (seg.payloadStop - seg.payloadStart).toInt()
                    if (pLen >= JpegProvenanceWriter.XMP_APP1_HEADER.size) {
                        inRaf.seek(seg.payloadStart)
                        val header = ByteArray(JpegProvenanceWriter.XMP_APP1_HEADER.size)
                        inRaf.readFully(header)
                        if (header.contentEquals(JpegProvenanceWriter.XMP_APP1_HEADER)) {
                            val xmlBytes = ByteArray(pLen - JpegProvenanceWriter.XMP_APP1_HEADER.size)
                            inRaf.readFully(xmlBytes)
                            return String(xmlBytes, StandardCharsets.UTF_8)
                        }
                    }
                }
            }
            null
        } catch (_: Throwable) {
            null
        } finally {
            inRaf.close()
        }
    }

    private fun readPngXmp(file: File): String? {
        val inRaf = RandomAccessFile(file, "r")
        return try {
            val chunks = PngProvenanceWriter.scanChunks(inRaf)
            for (chunk in chunks) {
                if (chunk.type == "iTXt") {
                    val dLen = (chunk.dataStop - chunk.dataStart).toInt()
                    if (dLen >= PngProvenanceWriter.PNG_XMP_KEYWORD.length + 5) {
                        inRaf.seek(chunk.dataStart)
                        val data = ByteArray(dLen)
                        inRaf.readFully(data)
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
        } finally {
            inRaf.close()
        }
    }

    private fun readWebpXmp(file: File): String? {
        val inRaf = RandomAccessFile(file, "r")
        return try {
            val chunks = WebpProvenanceWriter.scanChunks(inRaf)
            val xmpChunk = chunks.firstOrNull { it.fourCc == "XMP " }
            if (xmpChunk != null) {
                val dLen = (xmpChunk.dataStop - xmpChunk.dataStart).toInt()
                inRaf.seek(xmpChunk.dataStart)
                val data = ByteArray(dLen)
                inRaf.readFully(data)
                String(data, StandardCharsets.UTF_8)
            } else {
                null
            }
        } catch (_: Throwable) {
            null
        } finally {
            inRaf.close()
        }
    }

    private fun readMp4Xmp(file: File): String? {
        val inRaf = RandomAccessFile(file, "r")
        return try {
            val boxes = Mp4ProvenanceWriter.scanBoxes(inRaf)
            val xmpBox = boxes.firstOrNull { it.isXmp }
            if (xmpBox != null) {
                val dLen = (xmpBox.dataStop - xmpBox.dataStart).toInt()
                inRaf.seek(xmpBox.dataStart)
                val data = ByteArray(dLen)
                inRaf.readFully(data)
                String(data, StandardCharsets.UTF_8)
            } else {
                null
            }
        } catch (_: Throwable) {
            null
        } finally {
            inRaf.close()
        }
    }
}

