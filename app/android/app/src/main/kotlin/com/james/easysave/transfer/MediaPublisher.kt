package com.james.easysave.transfer

import java.io.File
import java.io.InputStream

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
     * Copies sourceFile content into the pending entry while computing MD5 in a single stream pass,
     * then publishes the entry by setting IS_PENDING = 0.
     */
    fun copyAndPublish(
        handle: PublishedHandle,
        sourceFile: File,
        mime: String,
    ): PublishedMedia

    /**
     * Deletes a pending entry by mediaId (used during kill recovery or cleanup).
     */
    fun deletePending(mediaId: String)

    /**
     * Opens an InputStream to the published media entry for readback verification.
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

    override fun copyAndPublish(
        handle: PublishedHandle,
        sourceFile: File,
        mime: String,
    ): PublishedMedia = PublishedMedia(
        mediaId = handle.mediaId,
        title = handle.displayName,
        relativePath = handle.relativePath,
        md5 = "00000000000000000000000000000000",
        size = if (sourceFile.exists()) sourceFile.length() else 0L,
        thread = "bg",
    )

    override fun deletePending(mediaId: String) {}

    override fun openInputStream(mediaId: String): InputStream = java.io.ByteArrayInputStream(ByteArray(0))
}

