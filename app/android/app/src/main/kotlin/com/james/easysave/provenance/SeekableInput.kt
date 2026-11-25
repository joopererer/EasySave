package com.james.easysave.provenance

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

interface SeekableInput : AutoCloseable {
    val length: Long
    val bytesRead: Long
    fun seek(position: Long)
    fun read(b: ByteArray, off: Int, len: Int): Int
    fun readFully(b: ByteArray, off: Int = 0, len: Int = b.size) {
        var n = 0
        while (n < len) {
            val count = read(b, off + n, len - n)
            if (count < 0) throw java.io.EOFException("Unexpected EOF after $n bytes (expected $len)")
            n += count
        }
    }
}

class RafSeekableInput(private val raf: RandomAccessFile) : SeekableInput {
    constructor(file: File) : this(RandomAccessFile(file, "r"))

    private var _bytesRead = 0L
    override val length: Long get() = raf.length()
    override val bytesRead: Long get() = _bytesRead

    override fun seek(position: Long) {
        raf.seek(position)
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        val count = raf.read(b, off, len)
        if (count > 0) _bytesRead += count
        return count
    }

    override fun close() {
        raf.close()
    }
}

class ByteArraySeekableInput(private val data: ByteArray) : SeekableInput {
    private var position = 0L
    private var _bytesRead = 0L
    override val length: Long get() = data.size.toLong()
    override val bytesRead: Long get() = _bytesRead

    override fun seek(pos: Long) {
        position = pos.coerceIn(0L, data.size.toLong())
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (position >= data.size) return -1
        val available = (data.size - position).toInt()
        val toRead = minOf(len, available)
        System.arraycopy(data, position.toInt(), b, off, toRead)
        position += toRead
        _bytesRead += toRead
        return toRead
    }

    override fun close() {}
}

class ChannelSeekableInput(
    private val channel: FileChannel,
    private val onClose: (() -> Unit)? = null,
) : SeekableInput {
    private var _bytesRead = 0L
    override val length: Long get() = channel.size()
    override val bytesRead: Long get() = _bytesRead

    override fun seek(position: Long) {
        channel.position(position)
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        val buf = ByteBuffer.wrap(b, off, len)
        val count = channel.read(buf)
        if (count > 0) _bytesRead += count
        return count
    }

    override fun close() {
        try {
            channel.close()
        } finally {
            onClose?.invoke()
        }
    }
}
