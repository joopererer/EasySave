package com.james.easysave

import android.content.ContentResolver
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.io.FileInputStream
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * Seekable data source interface for reading container formats (like MP4/MOV)
 * without loading the whole file or relying on ContentResolver.
 */
interface SeekableByteSource {
    val size: Long
    fun position(): Long
    fun seek(position: Long)
    fun read(buffer: ByteArray, offset: Int, length: Int): Int

    fun readFully(buffer: ByteArray): Boolean {
        var total = 0
        while (total < buffer.size) {
            val count = read(buffer, total, buffer.size - total)
            if (count <= 0) return false
            total += count
        }
        return true
    }
}

class FileChannelSource(private val channel: FileChannel) : SeekableByteSource {
    override val size: Long get() = channel.size()
    override fun position(): Long = channel.position()
    override fun seek(position: Long) {
        channel.position(position)
    }
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val byteBuffer = ByteBuffer.wrap(buffer, offset, length)
        return channel.read(byteBuffer)
    }
}

class RandomAccessFileSource(private val raf: RandomAccessFile) : SeekableByteSource {
    override val size: Long get() = raf.length()
    override fun position(): Long = raf.filePointer
    override fun seek(position: Long) {
        raf.seek(position)
    }
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        return raf.read(buffer, offset, length)
    }
}

class ByteArraySource(private val bytes: ByteArray) : SeekableByteSource {
    private var pos = 0L
    override val size: Long get() = bytes.size.toLong()
    override fun position(): Long = pos
    override fun seek(position: Long) {
        pos = position.coerceIn(0L, size)
    }
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (pos >= size) return -1
        val available = (size - pos).toInt()
        val toRead = minOf(length, available)
        System.arraycopy(bytes, pos.toInt(), buffer, offset, toRead)
        pos += toRead
        return toRead
    }
}

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
 *    data, stop at the `XMP ` chunk;
 *  * MP4 / MOV: top-level boxes are walked via [SeekableByteSource] using
 *    [FileChannel.position] (never InputStream.skip). Returns all complete
 *    XMP uuid boxes concatenated in file order.
 *
 * The result is the **byte array that was read**, never a byte count: the Dart
 * side parses these bytes with the existing XMP readers.
 */
object MediaHeaderReader {
    /** JPEG: enough for the APP1 segments at the start of the file. */
    const val JPEG_HEADER_BYTES = 128 * 1024

    /** Safety cap for the chunk walks (a corrupt file must not loop forever). */
    const val MAX_WALK_BYTES = 4 * 1024 * 1024

    /** Max XMP uuid box bytes read per box (matches maxMp4XmpBytes in package). */
    const val MAX_MP4_XMP_BYTES = 16 * 1024 * 1024

    /**
     * 16-byte UUID for Adobe XMP in MP4/MOV:
     * BE7ACFCB-97A9-42E8-9C71-999491E3AFAC
     */
    val XMP_UUID = byteArrayOf(
        0xBE.toByte(), 0x7A.toByte(), 0xCF.toByte(), 0xCB.toByte(),
        0x97.toByte(), 0xA9.toByte(), 0x42.toByte(), 0xE8.toByte(),
        0x9C.toByte(), 0x71.toByte(), 0x99.toByte(), 0x94.toByte(),
        0x91.toByte(), 0xE3.toByte(), 0xAF.toByte(), 0xAC.toByte()
    )

    private const val PNG_SIGNATURE = 8
    private const val WEBP_HEADER = 12

    /** True for the formats whose XMP the rebuild scan understands. */
    fun isSupported(mimeType: String?): Boolean {
        val mime = mimeType?.lowercase() ?: return false
        return mime.contains("jpeg") ||
            mime.contains("jpg") ||
            mime.contains("png") ||
            mime.contains("webp") ||
            mime.contains("mp4") ||
            mime.contains("quicktime") ||
            mime.startsWith("video/")
    }

    /**
     * Read the header bytes of [uri]. Returns null for unsupported
     * types, unreadable files, or when no XMP metadata is found.
     */
    fun readHeader(resolver: ContentResolver, uri: Uri, mimeType: String?): ByteArray? {
        val mime = mimeType?.lowercase() ?: return null
        return try {
            if (mime.contains("mp4") || mime.contains("quicktime") || mime.startsWith("video/")) {
                resolver.openFileDescriptor(uri, "r")?.use { pfd ->
                    FileInputStream(pfd.fileDescriptor).channel.use { channel ->
                        readMp4(FileChannelSource(channel))
                    }
                }
            } else {
                resolver.openInputStream(uri)?.use { input ->
                    when {
                        mime.contains("jpeg") || mime.contains("jpg") ->
                            readJpeg(input)
                        mime.contains("png") -> readPng(input)
                        mime.contains("webp") -> readWebp(input)
                        else -> null
                    }
                }
            }
        } catch (_: Exception) {
            null
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

    private fun readPng(input: InputStream): ByteArray? {
        val signature = ByteArray(PNG_SIGNATURE)
        if (!readFully(input, signature)) return null

        var walked = 0
        while (walked < MAX_WALK_BYTES) {
            val header = ByteArray(8)
            if (!readFully(input, header)) break
            val length = readU32BigEndian(header, 0)
            if (length < 0) break
            val type = String(header, 4, 4, Charsets.US_ASCII)

            if (type == "IDAT" || type == "IEND") {
                return null
            }

            if (type == "iTXt") {
                // Read full chunk payload + 4 bytes CRC
                val dataAndCrc = ByteArray(length + 4)
                if (!readFully(input, dataAndCrc)) break
                if (isXmpKeyword(dataAndCrc)) {
                    return signature + header + dataAndCrc
                }
                walked += 8 + length + 4
                continue
            }

            // Skip the chunk payload and its CRC.
            if (!skipFully(input, length.toLong() + 4)) break
            walked += 8 + length + 4
        }
        return null
    }

    private fun isXmpKeyword(dataAndCrc: ByteArray): Boolean {
        val keywordBytes = "XML:com.adobe.xmp".toByteArray(Charsets.US_ASCII)
        if (dataAndCrc.size < keywordBytes.size + 1) return false
        for (i in keywordBytes.indices) {
            if (dataAndCrc[i] != keywordBytes[i]) return false
        }
        return dataAndCrc[keywordBytes.size] == 0.toByte()
    }

    private fun readWebp(input: InputStream): ByteArray? {
        val header = ByteArray(WEBP_HEADER)
        if (!readFully(input, header)) return null

        var walked = 0
        while (walked < MAX_WALK_BYTES) {
            val chunkHeader = ByteArray(8)
            if (!readFully(input, chunkHeader)) break
            val size = readU32LittleEndian(chunkHeader, 4)
            if (size < 0) break
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
        return null
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

    /**
     * Checks if [source] has the 'ftyp' box header characteristic of MP4 / MOV.
     */
    fun isMp4(source: SeekableByteSource): Boolean {
        if (source.size < 8) return false
        source.seek(0)
        val header = ByteArray(8)
        if (!source.readFully(header)) return false
        return header[4] == 'f'.code.toByte() &&
            header[5] == 't'.code.toByte() &&
            header[6] == 'y'.code.toByte() &&
            header[7] == 'p'.code.toByte()
    }

    /**
     * Reads all complete XMP uuid boxes in [source], returning their bytes
     * concatenated in file order.
     *
     * Walks the top-level box chain jumping with seek, never reading mdat.
     * Retains all complete boxes found before any truncation point.
     * Returns null if no XMP uuid box is found, or if [source] is not MP4/MOV.
     */
    fun readMp4(source: SeekableByteSource): ByteArray? {
        if (!isMp4(source)) return null

        val fileSize = source.size
        var pos = 0L
        val xmpBoxes = mutableListOf<ByteArray>()

        while (pos + 8 <= fileSize) {
            source.seek(pos)
            val header = ByteArray(8)
            if (!source.readFully(header)) break

            val size32 = readU32BigEndianLong(header, 0)
            val type = String(header, 4, 4, Charsets.US_ASCII)

            val headerSize: Long
            val totalBoxSize: Long

            when {
                size32 == 1L -> {
                    if (pos + 16 > fileSize) break
                    val ext = ByteArray(8)
                    if (!source.readFully(ext)) break
                    val largeSize = readU64BigEndianLong(ext, 0)
                    if (largeSize < 16L) break
                    headerSize = 16L
                    totalBoxSize = largeSize
                }
                size32 == 0L -> {
                    headerSize = 8L
                    totalBoxSize = fileSize - pos
                }
                size32 < 8L -> {
                    break
                }
                else -> {
                    headerSize = 8L
                    totalBoxSize = size32
                }
            }

            if (totalBoxSize <= 0L || pos + totalBoxSize > fileSize) {
                // Truncated or invalid box: keep complete boxes found before
                break
            }

            if (type == "uuid" && totalBoxSize >= headerSize + 16L) {
                val uuid = ByteArray(16)
                source.seek(pos + headerSize)
                if (source.readFully(uuid) && uuid.contentEquals(XMP_UUID)) {
                    val payloadSize = totalBoxSize - headerSize
                    if (payloadSize in 1..MAX_MP4_XMP_BYTES) {
                        source.seek(pos)
                        val boxBytes = ByteArray(totalBoxSize.toInt())
                        if (source.readFully(boxBytes)) {
                            xmpBoxes.add(boxBytes)
                        }
                    }
                }
            }

            pos += totalBoxSize
        }

        if (xmpBoxes.isEmpty()) return null

        val totalBytes = xmpBoxes.sumOf { it.size }
        val result = ByteArray(totalBytes)
        var destPos = 0
        for (box in xmpBoxes) {
            System.arraycopy(box, 0, result, destPos, box.size)
            destPos += box.size
        }
        return result
    }

    private fun readU32BigEndianLong(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xFF) shl 24) or
            ((bytes[offset + 1].toLong() and 0xFF) shl 16) or
            ((bytes[offset + 2].toLong() and 0xFF) shl 8) or
            (bytes[offset + 3].toLong() and 0xFF)

    private fun readU64BigEndianLong(bytes: ByteArray, offset: Int): Long {
        var v = 0L
        for (i in 0 until 8) {
            v = (v shl 8) or (bytes[offset + i].toLong() and 0xFF)
        }
        return v
    }
}