package com.james.easysave

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowAlertDialog
import org.robolectric.Shadows.shadowOf
import android.os.Looper
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w360dp-h640dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SelectPanelAiTest {
    private fun texts(view: View): List<TextView> =
        (if (view is TextView) listOf(view) else emptyList()) +
            (if (view is ViewGroup) (0 until view.childCount).flatMap { texts(view.getChildAt(it)) } else emptyList())

    @Test fun realPanelRendersBadgeBesideTitleForEveryPlatformAndDisclosesLabel() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        for ((platform, label) in mapOf("xiaohongshu" to "可能含AI生成内容", "x" to "AI-generated",
            "tiktok" to "Contains AI-generated media", "instagram" to "AI content")) {
            val panel = SelectPanelView(activity) {}
            try {
                activity.setContentView(panel)
                panel.setPostMetadata("$platform post", mapOf("text" to label, "source" to "platform"))
                panel.setItems(listOf(mapOf("video" to false)))
                shadowOf(Looper.getMainLooper()).idle()
                panel.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(1920, View.MeasureSpec.EXACTLY))
                panel.layout(0, 0, 1080, 1920)
                val bitmap = Bitmap.createBitmap(1080, 1920, Bitmap.Config.ARGB_8888)
                panel.draw(Canvas(bitmap))
                val evidence = File("build/reports/ai-panel/$platform.png")
                evidence.parentFile!!.mkdirs()
                evidence.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                val badge = texts(panel).single { it.text == "AI" }
                val title = texts(panel).single { it.text == "$platform post" }
                assertSame(title.parent, badge.parent)
                assertTrue(badge.isShown)
                assertTrue(badge.width > 0 && badge.height > 0)
                assertTrue(badge.left >= title.right)
                badge.performClick()
                val dialog = ShadowAlertDialog.getLatestAlertDialog()
                assertTrue(dialog.isShowing)
                val content = texts(dialog.window!!.decorView).map { it.text.toString() }
                assertTrue(content.contains(label))
                assertTrue(content.contains("平台识别"))
                dialog.dismiss()
                panel.setPostMetadata("ordinary", null)
                assertFalse(badge.isShown)
            } finally { panel.release() }
        }
        activity.finish()
    }

    @Test fun blankLabelsStayHiddenAndAuthorSourceIsDisclosed() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val panel = SelectPanelView(activity) {}
        try {
            activity.setContentView(panel)
            for (label in listOf(null, emptyMap<String, String>(), mapOf("text" to "  "))) {
                panel.setPostMetadata(null, label)
                assertFalse(texts(panel).single { it.text == "AI" }.isShown)
            }
            panel.setPostMetadata(null, mapOf("text" to "作者声明：AI", "source" to "author"))
            texts(panel).single { it.text == "AI" }.performClick()
            val dialog = ShadowAlertDialog.getLatestAlertDialog()
            assertTrue(texts(dialog.window!!.decorView).any { it.text.toString() == "作者声明" })
            dialog.dismiss()
        } finally { panel.release(); activity.finish() }
    }
}
