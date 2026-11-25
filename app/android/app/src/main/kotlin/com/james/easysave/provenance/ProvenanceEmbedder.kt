package com.james.easysave.provenance

import java.io.File
import java.io.OutputStream

/**
 * Public entry point for embedding provenance records into media files.
 * Pure JVM, no Android dependencies.
 */
object ProvenanceEmbedder {

    fun embedToStream(input: File, outputStream: OutputStream, record: ProvenanceRecord): StreamingFileRewriter.WriteResult {
        require(input.exists()) { "Input file does not exist: ${input.path}" }
        val format = detectFormat(input)
        return when (format) {
            MediaFormat.JPEG -> JpegProvenanceWriter.embedToStream(input, outputStream, record)
            MediaFormat.PNG -> PngProvenanceWriter.embedToStream(input, outputStream, record)
            MediaFormat.WEBP -> WebpProvenanceWriter.embedToStream(input, outputStream, record)
            MediaFormat.MP4 -> Mp4ProvenanceWriter.embedToStream(input, outputStream, record)
            MediaFormat.UNSUPPORTED -> {
                throw UnsupportedOperationException(
                    "Cannot embed XMP in this container: ${input.name}. Still containers like HEIC/AVIF/GIF are skipped by design."
                )
            }
        }
    }

    fun embed(input: File, output: File, record: ProvenanceRecord) {
        output.outputStream().use { embedToStream(input, it, record) }
    }

    enum class MediaFormat {
        JPEG, PNG, WEBP, MP4, UNSUPPORTED
    }

    fun detectFormat(input: SeekableInput): MediaFormat {
        if (input.length < 4) return MediaFormat.UNSUPPORTED
        input.seek(0)
        val header = ByteArray(16)
        val readCount = input.read(header, 0, 16)
        if (readCount < 4) return MediaFormat.UNSUPPORTED

        // JPEG: 0xFF 0xD8 0xFF
        if ((header[0].toInt() and 0xFF) == 0xFF && (header[1].toInt() and 0xFF) == 0xD8) {
            return MediaFormat.JPEG
        }

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if (readCount >= 8 &&
            (header[0].toInt() and 0xFF) == 0x89 && header[1] == 0x50.toByte() &&
            header[2] == 0x4E.toByte() && header[3] == 0x47.toByte()
        ) {
            return MediaFormat.PNG
        }

        // WebP: RIFF .... WEBP
        if (readCount >= 12 &&
            header[0] == 'R'.code.toByte() && header[1] == 'I'.code.toByte() &&
            header[2] == 'F'.code.toByte() && header[3] == 'F'.code.toByte() &&
            header[8] == 'W'.code.toByte() && header[9] == 'E'.code.toByte() &&
            header[10] == 'B'.code.toByte() && header[11] == 'P'.code.toByte()
        ) {
            return MediaFormat.WEBP
        }

        // MP4 / MOV: ftyp / moov / mdat
        if (readCount >= 8) {
            val type = String(header, 4, 4, Charsets.US_ASCII)
            if (type == "ftyp" || type == "moov" || type == "mdat" || type == "free" || type == "skip" || type == "wide") {
                if (type == "ftyp" && readCount >= 12) {
                    val major = String(header, 8, 4, Charsets.US_ASCII)
                    // Check if it's HEIF / AVIF still (these are not embeddable)
                    if (major.startsWith("heic") || major.startsWith("heix") || major.startsWith("mif1") || major.startsWith("avif")) {
                        return MediaFormat.UNSUPPORTED
                    }
                }
                return MediaFormat.MP4
            }
        }

        return MediaFormat.UNSUPPORTED
    }

    fun detectFormat(file: File): MediaFormat {
        val ext = file.extension.lowercase()
        val format = try {
            RafSeekableInput(file).use { detectFormat(it) }
        } catch (_: Throwable) {
            MediaFormat.UNSUPPORTED
        }
        if (format != MediaFormat.UNSUPPORTED) return format

        return when (ext) {
            "jpg", "jpeg" -> MediaFormat.JPEG
            "png" -> MediaFormat.PNG
            "webp" -> MediaFormat.WEBP
            "mp4", "mov" -> MediaFormat.MP4
            else -> MediaFormat.UNSUPPORTED
        }
    }
}
