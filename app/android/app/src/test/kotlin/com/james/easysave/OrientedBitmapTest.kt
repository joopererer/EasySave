package com.james.easysave

import android.graphics.Bitmap
import android.graphics.Color
import android.content.ContentProvider
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.shadows.ShadowContentResolver
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class OrientedBitmapTest {
    @Test fun allEightExifFixturesDecodeWithMatchingThumbnailAndFullAspectAndCorners() {
        val pool = Executors.newSingleThreadExecutor()
        val context = RuntimeEnvironment.getApplication()
        val provider = GalleryProvider().apply {
            attachInfo(context, ProviderInfo().apply { authority = "media" })
        }
        ShadowContentResolver.registerProviderInternal("media", provider)
        val corners = listOf(
            listOf(Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW),
            listOf(Color.GREEN, Color.RED, Color.YELLOW, Color.BLUE),
            listOf(Color.YELLOW, Color.BLUE, Color.GREEN, Color.RED),
            listOf(Color.BLUE, Color.YELLOW, Color.RED, Color.GREEN),
            listOf(Color.RED, Color.BLUE, Color.GREEN, Color.YELLOW),
            listOf(Color.BLUE, Color.RED, Color.YELLOW, Color.GREEN),
            listOf(Color.YELLOW, Color.GREEN, Color.BLUE, Color.RED),
            listOf(Color.GREEN, Color.YELLOW, Color.RED, Color.BLUE))
        try {
            for (orientation in 1..8) {
                val source = Bitmap.createBitmap(160, 80, Bitmap.Config.ARGB_8888)
                for (y in 0 until 80) for (x in 0 until 160) source.setPixel(x, y,
                    corners[0][(if (y >= 40) 2 else 0) + (if (x >= 80) 1 else 0)])
                // Retained test vectors under build: no cleanup of unrelated temp files.
                val file = File("build/build24-exif/orientation-$orientation.jpg")
                file.parentFile!!.mkdirs()
                file.outputStream().use { assertTrue(source.compress(Bitmap.CompressFormat.JPEG, 100, it)) }
                source.recycle()
                ExifInterface(file).apply {
                    setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString()); saveAttributes()
                }
                val bytes = file.readBytes()
                val full = pool.submit<Bitmap> { OrientedBitmap.decode(bytes, 200)!! }.get(10, TimeUnit.SECONDS)
                val thumb = pool.submit<Bitmap> { OrientedBitmap.decode(bytes, 20)!! }.get(10, TimeUnit.SECONDS)
                assertEquals(if (orientation >= 5) 80 else 160, full.width)
                assertEquals(if (orientation >= 5) 160 else 80, full.height)
                assertEquals(full.width.toDouble() / full.height, thumb.width.toDouble() / thumb.height, 0.001)
                for (image in listOf(full, thumb)) {
                    val points = listOf(1 to 1, image.width-2 to 1, 1 to image.height-2, image.width-2 to image.height-2)
                    points.forEachIndexed { i, (x,y) ->
                        val actual = image.getPixel(x,y); val expected = corners[orientation-1][i]
                        assertTrue("orientation=$orientation corner=$i", kotlin.math.abs(Color.red(actual)-Color.red(expected)) < 25 &&
                            kotlin.math.abs(Color.green(actual)-Color.green(expected)) < 25 && kotlin.math.abs(Color.blue(actual)-Color.blue(expected)) < 25)
                    }
                    image.recycle()
                }
                assertArrayEquals(bytes, file.readBytes())
                assertEquals(orientation, ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1))
                pool.submit {
                    PublicMediaWriter.save(context, file, "image/jpeg", "Build24Synthetic", "orientation_${orientation}.jpg")
                }.get(10, TimeUnit.SECONDS)
                assertArrayEquals(bytes, provider.output.readBytes())
                assertEquals(orientation, ExifInterface(provider.output).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1))
            }
        } finally { pool.shutdownNow() }
    }

    /** Host-only MediaStore provider: exercise the real album writer, never a device album. */
    private class GalleryProvider : ContentProvider() {
        val output = File("build/build24-exif/mock-gallery.jpg")
        private var filename = ""
        override fun onCreate() = true
        override fun getType(uri: Uri) = "image/jpeg"
        override fun insert(uri: Uri, values: ContentValues?): Uri {
            filename = values!!.getAsString("_display_name")
            return Uri.parse("content://media/external/images/media/24")
        }
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
            selectionArgs: Array<out String>?, sortOrder: String?): Cursor =
            MatrixCursor(projection ?: arrayOf("_id")).apply {
                if (uri.lastPathSegment == "24") addRow(arrayOf(filename))
            }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
            ParcelFileDescriptor.open(output, if (mode.startsWith("w"))
                ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE or ParcelFileDescriptor.MODE_READ_WRITE
                else ParcelFileDescriptor.MODE_READ_ONLY)
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 1
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 1
    }

    @Test fun mainThreadDecodeIsRejectedBeforeReadingExifOrPixels() {
        assertThrows(IllegalStateException::class.java) { OrientedBitmap.decode(byteArrayOf(), 100) }
        assertThrows(IllegalStateException::class.java) { SharedPreviewBridge.image("synthetic") }
    }
}
