package com.james.easysave.transfer

import com.james.easysave.provenance.ByteArraySeekableInput
import com.james.easysave.provenance.SeekableInput
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream

data class PublishedHandle(
    val mediaId: String,
    val uriString: String,
    val displayName: String,
    val relativePath: String,
)

data class PublishedMedia(
    val mediaId: String,
    val title: String,
    val relativePath: String,
    val md5: String,
    val size: Long,
    val thread: String,
    val duration: Long? = null,
)

interface MediaPublisher {
    /**
     * Checks if a file with the given name (or its .xmp sidecar) already exists in the relative path.
     */
    fun exists(relativePath: String, displayName: String): Boolean

    /**
     * Inserts a pending entry into MediaStore with IS_PENDING = 1.
     * Throws if displayName exists or is invalid.
     */
    fun insertPending(
        relativePath: String,
        displayName: String,
        mime: String,
        sourceFile: File,
    ): PublishedHandle

    /**
     * Opens an OutputStream to the pending entry to write content.
     */
    fun openOutputStream(handle: PublishedHandle): OutputStream

    /**
     * Publishes the pending entry (sets IS_PENDING = 0) and returns PublishedMedia.
     */
    fun publish(
        handle: PublishedHandle,
        md5: String,
        size: Long,
        mime: String,
    ): PublishedMedia

    /**
     * Deletes a pending entry by mediaId (used during kill recovery or cleanup).
     */
    fun deletePending(mediaId: String)

    /**
     * Opens a seekable input to the published media entry for readback verification.
     */
    fun openSeekableInput(mediaId: String): SeekableInput

    /**
     * Opens an InputStream to the published media entry.
     */
    fun openInputStream(mediaId: String): InputStream
}

open class NoOpMediaPublisher : MediaPublisher {
    override fun exists(relativePath: String, displayName: String): Boolean = false
    override fun insertPending(
        relativePath: String,
        displayName: String,
        mime: String,
        sourceFile: File,
    ): PublishedHandle = PublishedHandle(
        mediaId = "noop-id",
        uriString = "content://noop",
        displayName = displayName,
        relativePath = relativePath,
    )

    override fun openOutputStream(handle: PublishedHandle): OutputStream = ByteArrayOutputStream()

    override fun publish(
        handle: PublishedHandle,
        md5: String,
        size: Long,
        mime: String,
    ): PublishedMedia = PublishedMedia(
        mediaId = handle.mediaId,
        title = handle.displayName,
        relativePath = handle.relativePath,
        md5 = md5,
        size = size,
        thread = "bg",
    )

    override fun deletePending(mediaId: String) {}

    override fun openSeekableInput(mediaId: String): SeekableInput = ByteArraySeekableInput(ByteArray(0))

    override fun openInputStream(mediaId: String): InputStream = ByteArrayInputStream(ByteArray(0))
}
