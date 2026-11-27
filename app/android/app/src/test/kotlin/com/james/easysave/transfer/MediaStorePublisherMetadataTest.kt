package com.james.easysave.transfer

import android.provider.MediaStore
import com.james.easysave.MediaMetadataProbe
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class MediaStorePublisherMetadataTest {
    @Test
    fun `buildPendingValues includes video duration, dimensions, and video mime`() {
        val publisher = MediaStorePublisher(RuntimeEnvironment.getApplication())
        val meta = MediaMetadataProbe.VideoMeta(durationMs = 15_400L, width = 1080, height = 1920)

        val values = publisher.buildPendingValues(
            displayName = "xhs_video_1.mp4",
            mime = "video/mp4",
            relativePath = "Movies/EasySave/",
            meta = meta,
        )

        assertEquals("xhs_video_1.mp4", values.getAsString(MediaStore.MediaColumns.DISPLAY_NAME))
        assertEquals("video/mp4", values.getAsString(MediaStore.MediaColumns.MIME_TYPE))
        assertTrue(values.getAsString(MediaStore.MediaColumns.MIME_TYPE).startsWith("video/"))
        assertEquals("Movies/EasySave/", values.getAsString(MediaStore.MediaColumns.RELATIVE_PATH))
        assertEquals(1, values.getAsInteger("is_pending"))
        assertTrue((values.getAsLong(MediaStore.Video.Media.DURATION) ?: 0L) > 0L)
        assertEquals(15_400L, values.getAsLong(MediaStore.Video.Media.DURATION))
        assertEquals(1080, values.getAsInteger(MediaStore.Video.Media.WIDTH))
        assertEquals(1920, values.getAsInteger(MediaStore.Video.Media.HEIGHT))
    }
}

