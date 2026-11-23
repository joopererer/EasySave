package com.james.easysave.provenance

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile

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

    private const val BUFFER_SIZE = 64 * 1024

    fun rewrite(input: File, output: File, regions: List<ReplacementRegion>) {
        val sorted = regions.sortedBy { it.start }
        val inLen = input.length()
        val tempOutput = File(output.parentFile, output.name + ".tmp_${System.nanoTime()}")

        val inStream = FileInputStream(input)
        val inChannel = inStream.channel
        val outStream = FileOutputStream(tempOutput)
        val outChannel = outStream.channel
        val buffer = ByteArray(BUFFER_SIZE)

        try {
            var position = 0L
            for (region in sorted) {
                if (region.start > position) {
                    var remaining = region.start - position
                    inChannel.position(position)
                    while (remaining > 0) {
                        val toRead = if (remaining > BUFFER_SIZE) BUFFER_SIZE else remaining.toInt()
                        val bytesRead = inStream.read(buffer, 0, toRead)
                        if (bytesRead == -1) break
                        outStream.write(buffer, 0, bytesRead)
                        remaining -= bytesRead
                    }
                }
                if (region.replacement.isNotEmpty()) {
                    outStream.write(region.replacement)
                }
                position = region.stop
            }
            if (position < inLen) {
                var remaining = inLen - position
                inChannel.position(position)
                while (remaining > 0) {
                    val toRead = if (remaining > BUFFER_SIZE) BUFFER_SIZE else remaining.toInt()
                    val bytesRead = inStream.read(buffer, 0, toRead)
                    if (bytesRead == -1) break
                    outStream.write(buffer, 0, bytesRead)
                    remaining -= bytesRead
                }
            }
            outChannel.force(true)
        } finally {
            inStream.close()
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

