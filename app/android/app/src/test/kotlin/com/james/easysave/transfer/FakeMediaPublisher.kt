package com.james.easysave.transfer

import com.james.easysave.ExportNames
import com.james.easysave.MediaImportPolicy
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

class FakeMediaPublisher : MediaPublisher {

    data class Entry(
        val mediaId: String,
        val relativePath: String,
        val displayName: String,
        val mime: String,
        var data: ByteArray?,
        var isPending: Boolean,
    )

    val entries = mutableMapOf<String, Entry>()
    private var idCounter = 1000

    override fun exists(relativePath: String, displayName: String): Boolean {
        return entries.values.any {
            it.relativePath == relativePath &&
                (it.displayName == displayName || it.displayName == "$displayName.xmp") &&
                !it.isPending
        }
    }

    override fun insertPending(
        relativePath: String,
        displayName: String,
        mime: String,
        sourceFile: File,
    ): PublishedHandle {
        ExportNames.requireClean(displayName)
        MediaImportPolicy.requireAllowed(mime)
        check(!exists(relativePath, displayName)) { "Target filename already exists: $displayName" }

        val id = (idCounter++).toString()
        entries[id] = Entry(
            mediaId = id,
            relativePath = relativePath,
            displayName = displayName,
            mime = mime,
            data = null,
            isPending = true,
        )
        return PublishedHandle(
            mediaId = id,
            uriString = "fake://$id",
            displayName = displayName,
            relativePath = relativePath,
        )
    }

    override fun copyAndPublish(
        handle: PublishedHandle,
        sourceFile: File,
        mime: String,
    ): PublishedMedia {
        val entry = entries[handle.mediaId] ?: error("Pending entry not found: ${handle.mediaId}")
        val bytes = sourceFile.readBytes()
        val md = MessageDigest.getInstance("MD5")
        val md5Hex = md.digest(bytes).joinToString("") { "%02x".format(it) }
        entry.data = bytes
        entry.isPending = false

        return PublishedMedia(
            mediaId = handle.mediaId,
            title = handle.displayName,
            relativePath = handle.relativePath,
            md5 = md5Hex,
            size = bytes.size.toLong(),
            thread = "bg",
        )
    }

    override fun deletePending(mediaId: String) {
        val entry = entries[mediaId]
        if (entry != null && entry.isPending) {
            entries.remove(mediaId)
        }
    }

    override fun openInputStream(mediaId: String): InputStream {
        val entry = entries[mediaId] ?: error("Entry not found: $mediaId")
        val data = entry.data ?: error("No data in entry: $mediaId")
        return ByteArrayInputStream(data)
    }
}

