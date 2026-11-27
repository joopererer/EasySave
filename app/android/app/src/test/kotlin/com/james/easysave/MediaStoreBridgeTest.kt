package com.james.easysave

import android.Manifest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    @Test
    fun hiddenPathDetectsDotSegments() {
        assertTrue(MediaStoreBridge.isHiddenPath("MIUI/Gallery/.trashBin/EasySave/"))
        assertTrue(MediaStoreBridge.isHiddenPath(".trash/EasySave/"))
        assertTrue(MediaStoreBridge.isHiddenPath("Pictures/.hidden/"))
        assertFalse(MediaStoreBridge.isHiddenPath("Movies/EasySave/"))
        assertFalse(MediaStoreBridge.isHiddenPath("Pictures/EasySave/"))
        assertFalse(MediaStoreBridge.isHiddenPath(null))
    }

    @Test
    fun topRelDirTruncatesToTwoSegments() {
        assertEquals("Movies/EasySave", MediaStoreBridge.topRelDir("Movies/EasySave/"))
        assertEquals("MIUI/Gallery", MediaStoreBridge.topRelDir("MIUI/Gallery/cloud/.trashBin/"))
        assertEquals("unknown", MediaStoreBridge.topRelDir(null))
    }

    @Test
    fun allowedPublishPathOnlyAcceptsNonHiddenEasySaveDirs() {
        val albums = listOf("EasySave")
        assertTrue(MediaStoreBridge.isAllowedPublishPath("Movies/EasySave/", albums))
        assertTrue(MediaStoreBridge.isAllowedPublishPath("Movies/EasySave", albums))
        assertTrue(MediaStoreBridge.isAllowedPublishPath("movies/easysave/", albums))
        assertTrue(MediaStoreBridge.isAllowedPublishPath("Pictures/EasySave/", albums))
        assertTrue(MediaStoreBridge.isAllowedPublishPath("PICTURES/EASYSAVE", albums))
        assertTrue(MediaStoreBridge.isAllowedPublishPath("Download/EasySave/", albums))
        assertTrue(MediaStoreBridge.isAllowedPublishPath("DCIM/EasySave/", albums))
        assertTrue(MediaStoreBridge.isAllowedPublishPath("Pictures/EasySave/2026/", albums))
        assertFalse(MediaStoreBridge.isAllowedPublishPath("MIUI/Gallery/.trashBin/EasySave/", albums))
        assertFalse(MediaStoreBridge.isAllowedPublishPath("Pictures/.trash/EasySave/", albums))
        assertFalse(MediaStoreBridge.isAllowedPublishPath("Movies/OtherAlbum/", albums))
        assertFalse(MediaStoreBridge.isAllowedPublishPath(null, albums))
    }

    @Test
    fun classifyOwnerDistinguishesSelfLegacyOtherNull() {
        val self = "com.joopererer.easysave"
        assertEquals("self", MediaStoreBridge.classifyOwner(self, self))
        assertEquals("legacy", MediaStoreBridge.classifyOwner("com.james.easysave", self))
        assertEquals("other", MediaStoreBridge.classifyOwner("com.miui.gallery", self))
        assertEquals("null", MediaStoreBridge.classifyOwner(null, self))
    }
}
