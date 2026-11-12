package com.james.easysave

import android.content.ContentResolver
import android.content.ContentUris
import android.media.MediaMetadataRetriever
import android.provider.MediaStore
import java.io.File

/**
 * Read-only video metadata used by the album import.
 *
 * A video is inserted with `is_pending = 1`; MediaStore extracts DURATION when
 * the row is published. When that extraction does not happen (or happens late)
 * the album shows a 0-second video that still plays when opened. This object
 * reads the duration from the source file so the row can carry it, and decides
 * afterwards whether a MediaScanner pass is still needed.
 */
internal object MediaMetadataProbe {
    data class VideoMeta(val durationMs: Long, val width: Int, val height: Int)

    /** A video whose DURATION stayed unset has to be scanned again. */
    fun needsRescan(durationMs: Long?, video: Boolean): Boolean =
        video && (durationMs == null || durationMs <= 0L)

    /** Metadata keys of MediaMetadataRetriever, parsed; null without duration. */
    fun metaOf(
        durationText: String?,
        widthText: String?,
        heightText: String?,
    ): VideoMeta? {
        val duration = durationText?.trim()?.toLongOrNull() ?: return null
        if (duration <= 0L) return null
        return VideoMeta(
            duration,
            widthText?.trim()?.toIntOrNull()?.coerceAtLeast(0) ?: 0,
            heightText?.trim()?.toIntOrNull()?.coerceAtLeast(0) ?: 0,
        )
    }

    /** Duration/width/height of a local file, or null when unreadable. */
    fun probeFile(file: File): VideoMeta? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.path)
            metaOf(
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION),
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH),
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT),
            )
        } catch (_: Throwable) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    /** MediaStore DURATION of one saved video, or null when not visible. */
    fun durationOf(resolver: ContentResolver, mediaId: Long): Long? = runCatching {
        resolver.query(
            ContentUris.withAppendedId(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI, mediaId,
            ),
            arrayOf(MediaStore.Video.Media.DURATION), null, null, null,
        )?.use { cursor -> if (cursor.moveToFirst()) cursor.getLong(0) else null }
    }.getOrNull()
}
