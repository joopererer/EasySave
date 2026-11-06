package com.james.easysave

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.BitmapDrawable
import android.view.View
import android.widget.ImageView
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import android.os.Looper
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w360dp-h640dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SelectPanelThumbnailPreviewTest {
    @Test fun realFullscreenPaintsCachedThumbnailWhileOriginalIsPending() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val panel = SelectPanelView(activity) {}
        val release = CountDownLatch(1)
        try {
            activity.setContentView(panel)
            val density = panel.resources.displayMetrics.density
            fun dp(value: Int) = (value * density + 0.5f).toInt()
            val pixels = (panel.resources.displayMetrics.widthPixels - dp(28) - dp(8) * 2) / 3
            val key = "b".repeat(64)
            val thumb = Bitmap.createBitmap(120, 180, Bitmap.Config.ARGB_8888)
            thumb.eraseColor(Color.rgb(255, 150, 40))
            NativeThumbBitmaps.configure(activity)
            NativeThumbBitmaps.put("$key:$pixels", thumb, Long.MAX_VALUE)
            val request = mapOf("cacheKey" to key, "sharedImageKey" to key)
            panel.setItems(listOf(mapOf("thumbRequest" to request, "imageRequest" to request, "video" to false)))
            val pool = SelectPanelView::class.java.getDeclaredField("pool")
                .apply { isAccessible = true }.get(panel) as ExecutorService
            val started = CountDownLatch(2)
            repeat(2) { pool.execute { started.countDown(); release.await() } }
            assertTrue(started.await(2, TimeUnit.SECONDS))
            SelectPanelView::class.java.getDeclaredMethod("showPreview", Int::class.javaPrimitiveType)
                .apply { isAccessible = true }.invoke(panel, 0)
            fun field(name: String) = SelectPanelView::class.java.getDeclaredField(name)
                .apply { isAccessible = true }.get(panel)
            val image = field("previewImage") as ImageView
            assertSame(thumb, (image.drawable as BitmapDrawable).bitmap)
            assertEquals(ImageView.ScaleType.FIT_CENTER, image.scaleType)
            assertEquals(View.VISIBLE, (field("previewProgress") as View).visibility)
            panel.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(1920, View.MeasureSpec.EXACTLY))
            panel.layout(0, 0, 1080, 1920)
            val progress = field("previewProgress") as View
            assertTrue(progress.width > 0 && progress.height > 0)
            shadowOf(Looper.getMainLooper()).idleFor(64, TimeUnit.MILLISECONDS)
            val bitmap = Bitmap.createBitmap(1080, 1920, Bitmap.Config.ARGB_8888)
            panel.draw(Canvas(bitmap))
            val evidence = File("build/reports/build28-preview/thumbnail-loading.png")
            evidence.parentFile!!.mkdirs()
            evidence.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        } finally { release.countDown(); panel.release(); activity.finish() }
    }
}
