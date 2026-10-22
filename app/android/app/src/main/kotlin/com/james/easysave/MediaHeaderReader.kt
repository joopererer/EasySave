package com.james.easysave

import android.content.ContentResolver
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.io.InputStream

/**
 * Reads only the header bytes of a media file through [ContentResolver].
 *
 * The rebuild scan used to pull every file into a temporary copy
 * (photo_manager `originFile`) and read it completely, which is what made a
 * rebuild slow. The XMP we are after always sits in the header area, so the
 * native side now returns just those bytes:
 *
 *  * JPEG: the first 128 KB (the APP1 segments are at the very beginning);
 *  * PNG: the chunk headers are walked, the data of uninteresting chunks is
 *    skipped, and the scan stops at the XMP chunk (returned whole, so the
 *    Dart PNG reader can parse it unchanged);
 *  * WebP: same idea on the RIFF container - walk the chunks, skip their
 *    data, stop at the `XMP ` chunk.
 *
 * The result is the **byte array that was read**, never a byte count: the Dart
 * side parses these bytes with the existing XMP readers.
 */
object MediaHeaderReader {
    /** JPEG: enough for the APP1 segments at the start of the file. */
    const val JPEG_HEADER_BYTES = 128 * 1024

    /** Safety cap for the chunk walks (a corrupt file must not loop forever). */
    const val MAX_WALK_BYTES = 4 * 1024 * 1024

    private const val PNG_SIGNATURE = 8
    private const val WEBP_HEADER = 12

    /** True for the formats whose XMP the rebuild scan understands. */
    fun isSupported(mimeType: String?): Boolean {
        val mime = mimeType?.lowercase() ?: return false
        return mime.contains("jpeg") ||
            mime.contains("jpg") ||
            mime.contains("png") ||
            mime.contains("webp")
    }

    /**
     * Read the header bytes of [uri]. Returns an empty array for unsupported
     * types or unreadable files.
     */
    fun readHeader(resolver: ContentResolver, uri: Uri, mimeType: String?): ByteArray {
        val mime = mimeType?.lowercase() ?: return ByteArray(0)
        return try {
            resolver.openInputStream(uri)?.use { input ->
                when {
                    mime.contains("jpeg") || mime.contains("jpg") ->
                        readJpeg(input)
                    mime.contains("png") -> readPng(input)
                    mime.contains("webp") -> readWebp(input)
                    else -> ByteArray(0)
                }
            } ?: ByteArray(0)
        } catch (_: Exception) {
            ByteArray(0)
        }
    }

    private fun readJpeg(input: InputStream): ByteArray {
        val buffer = ByteArray(JPEG_HEADER_BYTES)
        var total = 0
        while (total < buffer.size) {
            val read = input.read(buffer, total, buffer.size - total)
            if (read <= 0) break
            total += read
        }
        return if (total == buffer.size) buffer else buffer.copyOf(total)
    }

    private fun readPng(input: InputStream): ByteArray {
        val signature = ByteArray(PNG_SIGNATURE)
        if (!readFully(input, signature)) return ByteArray(0)

        var walked = 0
        while (walked < MAX_WALK_BYTES) {
            val header = ByteArray(8)
            if (!readFully(input, header)) break
            val length = readU32BigEndian(header, 0)
            val type = String(header, 4, 4, Charsets.US_ASCII)
            if (type == "iTXt") {
                // The XMP chunk: return it whole so the Dart reader can parse
                // the keyword and the payload.
                val data = ByteArray(length)
                if (!readFully(input, data)) break
                return signature + header + data
            }
            // Skip the chunk payload and its CRC.
            if (!skipFully(input, length.toLong() + 4)) break
            walked += 8 + length + 4
        }
        return ByteArray(0)
    }

    private fun readWebp(input: InputStream): ByteArray {
        val header = ByteArray(WEBP_HEADER)
        if (!readFully(input, header)) return ByteArray(0)

        var walked = 0
        while (walked < MAX_WALK_BYTES) {
            val chunkHeader = ByteArray(8)
            if (!readFully(input, chunkHeader)) break
            val size = readU32LittleEndian(chunkHeader, 4)
            val fourCc = String(chunkHeader, 0, 4, Charsets.US_ASCII)
            if (fourCc == "XMP ") {
                val data = ByteArray(size)
                if (!readFully(input, data)) break
                return header + chunkHeader + data
            }
            // RIFF chunks are padded to an even size.
            val padding = if (size % 2 == 1) 1 else 0
            if (!skipFully(input, size.toLong() + padding)) break
            walked += 8 + size + padding
        }
        return ByteArray(0)
    }

    /**
     * Album (bucket) of [uri] as MediaStore reports it.
     *
     * `RELATIVE_PATH` / `BUCKET_DISPLAY_NAME` need API 29; on older devices
     * the deprecated `DATA` column provides the directory instead.
     */
    fun queryAlbum(resolver: ContentResolver, uri: Uri): Map<String, String?> {
        val result = HashMap<String, String?>()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val projection = arrayOf(
                    MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
                    MediaStore.Images.Media.RELATIVE_PATH,
                )
                resolver.query(uri, projection, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        result["bucket"] = cursor.getString(0)
                        result["relativePath"] = cursor.getString(1)
                    }
                }
            } else {
                val projection = arrayOf(MediaStore.Images.Media.DATA)
                resolver.query(uri, projection, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val data = cursor.getString(0)
                        result["data"] = data
                        result["bucket"] = data?.substringBeforeLast('/', "")
                    }
                }
            }
        } catch (_: Exception) {
            // Leave the map empty: the caller falls back to the known album
            // list.
        }
        return result
    }

    private fun readFully(input: InputStream, buffer: ByteArray): Boolean {
        var total = 0
        while (total < buffer.size) {
            val read = input.read(buffer, total, buffer.size - total)
            if (read <= 0) return false
            total += read
        }
        return true
    }

    private fun skipFully(input: InputStream, count: Long): Boolean {
        var remaining = count
        val scratch = ByteArray(8 * 1024)
        while (remaining > 0) {
            val chunk = minOf(remaining, scratch.size.toLong()).toInt()
            val read = input.read(scratch, 0, chunk)
            if (read <= 0) return false
            remaining -= read
        }
        return true
    }

    private fun readU32BigEndian(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xFF) shl 24) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 8) or
            (bytes[offset + 3].toInt() and 0xFF)

    private fun readU32LittleEndian(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)
}