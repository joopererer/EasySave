package com.james.easysave

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Native "选择下载" panel shown as a TYPE_APPLICATION_OVERLAY window. Plain
 * Android views (no FlutterView): attaching a FlutterView to an overlay window
 * proved unreliable on some devices (transparent SurfaceView, dead touch).
 * Thumbnails load off the main thread with the webview cookie jar; the chosen
 * indices are handed back through [onResult].
 */
class SelectPanelView(
    context: Context,
    private val onResult: (List<Int>?) -> Unit,
) : FrameLayout(context) {

    companion object {
        const val TAG = "V16SEL"
        private const val COLS = 3
        private const val TARGET_PX = 300
    }

    private class Cell(val thumb: String, val video: Boolean)

    private val main = Handler(Looper.getMainLooper())
    private val pool = Executors.newFixedThreadPool(6)
    private val cells = ArrayList<Cell>()
    private val selected = LinkedHashSet<Int>()
    private var finished = false

    private lateinit var countLabel: TextView
    private lateinit var allBtn: TextView
    private lateinit var downloadBtn: TextView
    private lateinit var grid: GridLayout

    init {
        setBackgroundColor(0x99000000.toInt())
        isClickable = true
        setOnClickListener { finish(null) }
        addView(
            buildSheet(),
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM)
        )
    }

    fun setItems(items: List<Any?>) {
        cells.clear()
        for (raw in items) {
            val m = raw as? Map<*, *> ?: continue
            cells.add(Cell(m["thumb"] as? String ?: "", m["video"] as? Boolean ?: false))
        }
        selected.clear()
        selected.addAll(cells.indices)
        main.post { render() }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun buildSheet(): View = sheet()

    private fun sheet(): View {
        val sheet = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(10), dp(14), 0)
            background = GradientDrawable().apply {
                cornerRadii = floatArrayOf(
                    dp(20).toFloat(), dp(20).toFloat(),
                    dp(20).toFloat(), dp(20).toFloat(), 0f, 0f, 0f, 0f
                )
                setColor(0xFF1C1B1A.toInt())
            }
        }
        sheet.layoutParams =
            LayoutParams(LayoutParams.MATCH_PARENT, (resources.displayMetrics.heightPixels * 0.72).toInt())

        sheet.addView(
            View(context).apply {
                background = GradientDrawable().apply {
                    cornerRadius = dp(2).toFloat()
                    setColor(0x40FFFFFF)
                }
            },
            LinearLayout.LayoutParams(dp(40), dp(4)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(8)
            }
        )

        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(4), 0, dp(6))
        }
        header.addView(
            TextView(context).apply {
                text = "选择要下载的内容"
                setTextColor(Color.WHITE)
                textSize = 16f
            }
        )
        countLabel = TextView(context).apply {
            setTextColor(0x99FFFFFF.toInt())
            textSize = 13f
        }
        header.addView(
            countLabel,
            LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
                .apply { leftMargin = dp(8) }
        )
        header.addView(View(context), LinearLayout.LayoutParams(0, 1).apply { weight = 1f })
        allBtn = TextView(context).apply {
            setTextColor(0xFFFF6A3D.toInt())
            textSize = 14f
            setPadding(dp(12), dp(6), dp(12), dp(6))
            setOnClickListener { toggleAll() }
        }
        header.addView(allBtn)
        header.addView(
            TextView(context).apply {
                text = "✕"
                setTextColor(0xB3FFFFFF.toInt())
                textSize = 20f
                setPadding(dp(12), dp(4), dp(6), dp(4))
                setOnClickListener { finish(null) }
            }
        )
        sheet.addView(header)

        grid = GridLayout(context).apply { columnCount = COLS }
        sheet.addView(
            grid,
            LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, 0).apply { weight = 1f }
        )

        downloadBtn = TextView(context).apply {
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            textSize = 16f
            background = GradientDrawable().apply {
                cornerRadius = dp(25).toFloat()
                setColor(0xFFFF5340.toInt())
            }
            setOnClickListener {
                if (selected.isNotEmpty()) finish(selected.toList())
            }
        }
        sheet.addView(
            downloadBtn,
            LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, dp(50)).apply {
                topMargin = dp(10)
                bottomMargin = dp(14)
            }
        )
        return sheet
    }

    private fun render() {
        grid.removeAllViews()
        val cell = (resources.displayMetrics.widthPixels - dp(28) - dp(8) * (COLS - 1)) / COLS
        for (i in cells.indices) {
            val box = FrameLayout(context)
            box.layoutParams = GridLayout.LayoutParams(
                GridLayout.spec(i / COLS), GridLayout.spec(i % COLS)
            ).apply {
                width = cell
                height = cell
                setMargins(0, 0, dp(8), dp(8))
            }
            box.background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(0xFF2A2928.toInt())
            }
            box.clipToOutline = true

            val iv = ImageView(context).apply {
                scaleType = ImageView.ScaleType.CENTER_CROP
            }
            box.addView(iv, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            if (cells[i].video) {
                box.addView(
                    TextView(context).apply {
                        text = "▶"
                        setTextColor(Color.WHITE)
                        textSize = 14f
                    },
                    LayoutParams(dp(26), dp(26), Gravity.BOTTOM or Gravity.START)
                )
            }
            val tick = TextView(context).apply {
                text = "✓"
                setTextColor(Color.WHITE)
                textSize = 13f
                gravity = Gravity.CENTER
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(0xFFFF5340.toInt())
                    setStroke(dp(2), Color.WHITE)
                }
            }
            box.addView(
                tick,
                LayoutParams(dp(24), dp(24), Gravity.TOP or Gravity.END)
                    .apply { setMargins(0, dp(6), dp(6), 0) }
            )
            val dim = View(context).apply { setBackgroundColor(0x99000000.toInt()) }
            box.addView(dim, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))

            fun sync() {
                val on = selected.contains(i)
                tick.visibility = if (on) View.VISIBLE else View.INVISIBLE
                dim.visibility = if (on) View.GONE else View.VISIBLE
            }
            sync()
            box.setOnClickListener {
                if (!selected.remove(i)) selected.add(i)
                sync()
                updateFooter()
            }
            grid.addView(box)
            loadThumb(cells[i].thumb, iv)
        }
        updateFooter()
    }

    private fun updateFooter() {
        val total = cells.size
        countLabel.text = "已选 ${selected.size}/$total"
        allBtn.text = if (total > 0 && selected.size == total) "取消全选" else "全选"
        downloadBtn.text = "下载 (${selected.size})"
        downloadBtn.alpha = if (selected.isEmpty()) 0.5f else 1f
    }

    private fun toggleAll() {
        selected.clear()
        if (selected.size != cells.size) selected.addAll(cells.indices)
        render()
    }

    private fun loadThumb(url: String, target: ImageView) {
        if (url.isEmpty()) return
        pool.execute {
            var bitmap: Bitmap? = null
            try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 10000
                conn.instanceFollowRedirects = true
                runCatching { android.webkit.CookieManager.getInstance().getCookie(url) }
                    .getOrNull()?.takeIf { it.isNotEmpty() }
                    ?.let { conn.setRequestProperty("Cookie", it) }
                conn.setRequestProperty(
                    "Accept",
                    "image/webp,image/apng,image/*,*/*;q=0.8"
                )
                conn.connect()
                if (conn.responseCode in 200..299) {
                    val bytes = conn.inputStream.use { it.readBytes() }
                    bitmap = decodeSampled(bytes, dp(TARGET_PX))
                }
                conn.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "thumb failed: ${e.message}")
            }
            val bmp = bitmap
            if (bmp != null) {
                main.post { if (target.isAttachedToWindow) target.setImageBitmap(bmp) }
            }
        }
    }

    /// Decode JPEG/PNG/WebP bytes downsampled to roughly [target] px — decoding
    /// a multi-MB original at full size was the main cause of slow thumbnails.
    private fun decodeSampled(bytes: ByteArray, target: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val w = bounds.outWidth
        val h = bounds.outHeight
        var sample = 1
        while (w / (sample * 2) >= target && h / (sample * 2) >= target) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
    }

    private fun finish(result: List<Int>?) {
        if (finished) return
        finished = true
        main.post { onResult(result) }
    }

    fun release() {
        pool.shutdownNow()
    }
}