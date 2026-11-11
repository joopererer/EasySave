package com.james.easysave

import android.Manifest
import org.junit.Assert.assertEquals
import org.junit.Test

class MediaStoreBridgeTest {
    private fun state(sdk: Int, vararg granted: String) =
        MediaStoreBridge.permissionState(sdk) { it in granted }

    @Test
    fun android13UsesMediaPermissions() {
        assertEquals("granted", state(33, Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO))
        assertEquals("denied", state(33, Manifest.permission.READ_MEDIA_IMAGES))
        assertEquals("denied", state(33, Manifest.permission.READ_EXTERNAL_STORAGE))
    }

    @Test
    fun android14SelectedPhotosIsPartial() {
        assertEquals("partial", state(34, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))
        assertEquals("granted", state(34, Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))
    }

    @Test
    fun android12UsesReadExternalStorage() {
        assertEquals("granted", state(31, Manifest.permission.READ_EXTERNAL_STORAGE))
        assertEquals("denied", state(31))
        assertEquals("denied", state(31, Manifest.permission.READ_MEDIA_IMAGES))
    }

    @Test
    fun bucketSelectionHasOnePlaceholderPerAlbum() {
        assertEquals("LOWER(bucket_display_name) IN (?,?)", MediaStoreBridge.bucketSelection(2))
    }
}
