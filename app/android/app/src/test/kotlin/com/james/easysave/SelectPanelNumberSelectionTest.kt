package com.james.easysave

import android.app.Activity
import android.widget.EditText
import android.widget.TextView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import java.util.concurrent.TimeUnit

/**
 * The overlay's "选择下载" panel without thumbnails: the user types the item
 * numbers and presses download. The panel must hand back exactly those indices
 * — the batch, the placeholder and the terminal history write all derive from
 * this list, so a wider list here is what once made the history list more files
 * than the user picked.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w360dp-h640dp-xxhdpi")
class SelectPanelNumberSelectionTest {

    private fun field(panel: SelectPanelView, name: String): Any? =
        SelectPanelView::class.java.getDeclaredField(name)
            .apply { isAccessible = true }.get(panel)

    private fun invoke(panel: SelectPanelView, name: String, vararg args: Any?) {
        val method = SelectPanelView::class.java.declaredMethods.first {
            it.name == name && it.parameterTypes.size == args.size
        }
        method.isAccessible = true
        method.invoke(panel, *args)
    }

    private fun item(index: Int) = mapOf(
        "thumbRequest" to mapOf("cacheKey" to "key-$index"),
        "imageRequest" to mapOf("cacheKey" to "key-$index"),
        "video" to false,
    )

    @Test
    fun typedNumbersAreTheOnlyIndicesHandedBack() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        var picked: List<Int>? = null
        val panel = SelectPanelView(activity) { picked = it }
        try {
            activity.setContentView(panel)
            panel.setItems((0 until 6).map { item(it) })
            ShadowLooper.shadowMainLooper().idle()
            // Thumbnails stay off by default, so nothing was expanded.
            assertFalse(field(panel, "showThumbs") as Boolean)
            assertTrue((field(panel, "shimmers") as List<*>).isEmpty())

            (field(panel, "specInput") as EditText).setText("1,3,5")
            invoke(panel, "applySpec")
            ShadowLooper.shadowMainLooper().idle()

            // Everything was selected before the numbers were applied.
            assertEquals(3, (field(panel, "selected") as Set<*>).size)
            assertEquals(
                "下载 (3)",
                (field(panel, "downloadBtn") as TextView).text.toString(),
            )

            invoke(panel, "finish", (field(panel, "selected") as Set<*>).filterIsInstance<Int>())
            ShadowLooper.shadowMainLooper().idleFor(50, TimeUnit.MILLISECONDS)

            assertNotNull(picked)
            assertEquals(listOf(0, 2, 4), picked)
        } finally {
            panel.release()
            activity.finish()
        }
    }

    @Test
    fun typedNumbersKeepTheirOneBasedMeaningForLivePhotos() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        var picked: List<Int>? = null
        val panel = SelectPanelView(activity) { picked = it }
        try {
            activity.setContentView(panel)
            panel.setItems((0 until 16).map { item(it) })
            ShadowLooper.shadowMainLooper().idle()
            (field(panel, "specInput") as EditText).setText("2,4,7-9")
            invoke(panel, "applySpec")
            ShadowLooper.shadowMainLooper().idle()
            invoke(panel, "finish", (field(panel, "selected") as Set<*>).filterIsInstance<Int>())
            ShadowLooper.shadowMainLooper().idleFor(50, TimeUnit.MILLISECONDS)
            assertEquals(listOf(1, 3, 6, 7, 8), picked)
        } finally {
            panel.release()
            activity.finish()
        }
    }
}
