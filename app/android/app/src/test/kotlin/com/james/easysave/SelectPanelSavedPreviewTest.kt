package com.james.easysave

import android.app.Activity
import android.content.ContentUris
import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.provider.MediaStore
import android.view.View
import android.widget.ImageView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

/**
 * An item the album already holds is opened from MediaStore: no network
 * request, no thumbnail placeholder and no loading spinner.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w360dp-h640dp-xxhdpi")
class SelectPanelSavedPreviewTest {

    private fun field(panel: SelectPanelView, name: String): Any? =
        SelectPanelView::class.java.getDeclaredField(name)
            .apply { isAccessible = true }.get(panel)

    private fun jpeg(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(0xFF3366CC.toInt())
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
        return out.toByteArray()
    }

    @Test
    fun savedImageIsReadFromTheAlbumWithoutProgress() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val panel = SelectPanelView(activity) {}
        try {
            activity.setContentView(panel)
            val mediaId = 4242L
            val uri: Uri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, mediaId,
            )
            shadowOf(activity.contentResolver).registerInputStream(
                uri, ByteArrayInputStream(jpeg(1200, 900)),
            )
            panel.setItems(
                listOf(
                    mapOf(
                        "thumbRequest" to mapOf("cacheKey" to "k"),
                        "imageRequest" to mapOf("cacheKey" to "k"),
                        "video" to false,
                        "saved" to true,
                        "savedMediaId" to mediaId.toString(),
                    ),
                ),
            )
            ShadowLooper.shadowMainLooper().idle()

            SelectPanelView::class.java
                .getDeclaredMethod("showPreview", Int::class.javaPrimitiveType)
                .apply { isAccessible = true }.invoke(panel, 0)

            // The decode runs off the main thread; give it a moment, then idle.
            Thread.sleep(300)
            ShadowLooper.shadowMainLooper().idle()

            val image = field(panel, "previewImage") as ImageView
            val shown = (image.drawable as BitmapDrawable?)?.bitmap
            assertNotNull("the album copy must be shown", shown)
            assertTrue(shown!!.width > 0 && shown.height > 0)
            assertEquals(ImageView.ScaleType.FIT_CENTER, image.scaleType)
            // No spinner for a file that is already on the device.
            assertEquals(View.GONE, (field(panel, "previewProgress") as View).visibility)
            assertTrue(field(panel, "previewOverlay")!!.let { (it as View).visibility == View.VISIBLE })
        } finally {
            panel.release()
            activity.finish()
        }
    }

    @Test
    fun aSavedIdTheAlbumNoLongerServesDecodesToNull() {
        // The panel falls back to the network path when the album no longer
        // serves the id; the decoder is what decides that.
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        try {
            val uri: Uri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, 999999L,
            )
            assertNull(NativeLocalBitmap.decode(activity, uri, 1080))
        } finally {
            activity.finish()
        }
    }
}
