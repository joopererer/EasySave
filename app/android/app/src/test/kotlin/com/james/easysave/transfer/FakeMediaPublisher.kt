package com.james.easysave.transfer

import com.james.easysave.ExportNames
import com.james.easysave.MediaImportPolicy
import com.james.easysave.PairSavePolicy
import com.james.easysave.provenance.ByteArraySeekableInput
import com.james.easysave.provenance.SeekableInput
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream

class FakeMediaPublisher : MediaPublisher {

    data class Entry(
        val mediaId: String,
        val relativePath: String,
        val displayName: String,
        val mime: String,
        var data: ByteArray?,
        var isPending: Boolean,
        var md5: String? = null,
        var outputStream: ByteArrayOutputStream? = null,
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
        val isSidecar = displayName.endsWith(".xmp")
        if (isSidecar) {
            ExportNames.requireClean(displayName.removeSuffix(".xmp"))
            require(mime == PairSavePolicy.SIDECAR_MIME) { "Invalid sidecar MIME: $mime" }
        } else {
            ExportNames.requireClean(displayName)
            MediaImportPolicy.requireAllowed(mime)
        }
        check(!exists(relativePath, displayName)) { "Target filename already exists: $displayName" }

        val id = (idCounter++).toString()
        val entry = Entry(
            mediaId = id,
            relativePath = relativePath,
            displayName = displayName,
            mime = mime,
            data = null,
            isPending = true,
        )
        entries[id] = entry
        return PublishedHandle(
            mediaId = id,
            uriString = "fake://$id",
            displayName = displayName,
            relativePath = relativePath,
        )
    }

    override fun openOutputStream(handle: PublishedHandle): OutputStream {
        val entry = entries[handle.mediaId] ?: error("Pending entry not found: ${handle.mediaId}")
        val baos = ByteArrayOutputStream()
        entry.outputStream = baos
        return baos
    }

    override fun publish(
        handle: PublishedHandle,
        md5: String,
        size: Long,
        mime: String,
    ): PublishedMedia {
        val entry = entries[handle.mediaId] ?: error("Pending entry not found: ${handle.mediaId}")
        val bytes = entry.outputStream?.toByteArray() ?: entry.data ?: ByteArray(0)
        entry.data = bytes
        entry.isPending = false
        entry.md5 = md5
        entry.outputStream = null

        return PublishedMedia(
            mediaId = handle.mediaId,
            title = handle.displayName,
            relativePath = handle.relativePath,
            md5 = md5,
            size = size,
            thread = "bg",
        )
    }

    override fun deletePending(mediaId: String) {
        val entry = entries[mediaId]
        if (entry != null && entry.isPending) {
            entries.remove(mediaId)
        }
    }

    override fun openSeekableInput(mediaId: String): SeekableInput {
        val entry = entries[mediaId] ?: error("Entry not found: $mediaId")
        val data = entry.data ?: error("No data in entry: $mediaId")
        return ByteArraySeekableInput(data)
    }

    override fun openInputStream(mediaId: String): InputStream {
        val entry = entries[mediaId] ?: error("Entry not found: $mediaId")
        val data = entry.data ?: error("No data in entry: $mediaId")
        return ByteArrayInputStream(data)
    }
}
