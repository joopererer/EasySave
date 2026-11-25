package com.james.easysave.provenance

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.OutputStream
import java.security.MessageDigest

/**
 * Pure JVM streaming file rewriter, copying chunks without reading whole files into memory.
 * Replicates file_rewriter.dart.
 */
object StreamingFileRewriter {
    class ReplacementRegion(
        val start: Long,
        val stop: Long,
        val replacement: ByteArray,
    )

    data class WriteResult(
        val bytesWritten: Long,
        val md5Hex: String,
    )

    const val BUFFER_SIZE = 1024 * 1024 // 1 MB buffer for high throughput

    fun rewriteToStream(
        input: File,
        outStream: OutputStream,
        regions: List<ReplacementRegion>,
        bufferSize: Int = BUFFER_SIZE,
    ): WriteResult {
        val md = MessageDigest.getInstance("MD5")
        val sorted = regions.sortedBy { it.start }
        val inLen = input.length()
        var bytesWritten = 0L

        val inStream = FileInputStream(input)
        val inChannel = inStream.channel
        val buffer = ByteArray(bufferSize)

        try {
            var position = 0L
            for (region in sorted) {
                if (region.start > position) {
                    var remaining = region.start - position
                    inChannel.position(position)
                    while (remaining > 0) {
                        val toRead = if (remaining > bufferSize) bufferSize else remaining.toInt()
                        val bytesRead = inStream.read(buffer, 0, toRead)
                        if (bytesRead == -1) break
                        md.update(buffer, 0, bytesRead)
                        outStream.write(buffer, 0, bytesRead)
                        bytesWritten += bytesRead
                        remaining -= bytesRead
                    }
                }
                if (region.replacement.isNotEmpty()) {
                    md.update(region.replacement)
                    outStream.write(region.replacement)
                    bytesWritten += region.replacement.size
                }
                position = region.stop
            }
            if (position < inLen) {
                var remaining = inLen - position
                inChannel.position(position)
                while (remaining > 0) {
                    val toRead = if (remaining > bufferSize) bufferSize else remaining.toInt()
                    val bytesRead = inStream.read(buffer, 0, toRead)
                    if (bytesRead == -1) break
                    md.update(buffer, 0, bytesRead)
                    outStream.write(buffer, 0, bytesRead)
                    bytesWritten += bytesRead
                    remaining -= bytesRead
                }
            }
            outStream.flush()
        } finally {
            inStream.close()
        }

        val md5Hex = md.digest().joinToString("") { "%02x".format(it) }
        return WriteResult(bytesWritten, md5Hex)
    }

    fun copyToStream(
        input: File,
        outStream: OutputStream,
        bufferSize: Int = BUFFER_SIZE,
    ): WriteResult {
        val md = MessageDigest.getInstance("MD5")
        var bytesWritten = 0L
        val buffer = ByteArray(bufferSize)
        val inStream = FileInputStream(input)
        try {
            while (true) {
                val n = inStream.read(buffer)
                if (n <= 0) break
                md.update(buffer, 0, n)
                outStream.write(buffer, 0, n)
                bytesWritten += n
            }
            outStream.flush()
        } finally {
            inStream.close()
        }
        val md5Hex = md.digest().joinToString("") { "%02x".format(it) }
        return WriteResult(bytesWritten, md5Hex)
    }

    fun rewrite(input: File, output: File, regions: List<ReplacementRegion>) {
        val tempOutput = File(output.parentFile, output.name + ".tmp_${System.nanoTime()}")
        val outStream = FileOutputStream(tempOutput)
        try {
            rewriteToStream(input, outStream, regions)
        } finally {
            outStream.close()
        }

        if (output.exists()) {
            output.delete()
        }
        if (!tempOutput.renameTo(output)) {
            // Fallback for atomic rename on some Windows configs
            tempOutput.copyTo(output, overwrite = true)
            tempOutput.delete()
        }
    }
}
