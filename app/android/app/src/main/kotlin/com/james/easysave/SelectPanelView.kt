package com.james.easysave

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.SurfaceTexture
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.MediaPlayer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.os.SystemClock
import android.view.GestureDetector
import android.view.KeyEvent
import android.widget.SeekBar
import java.util.Locale
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import kotlin.math.hypot

/**
 * Native "选择下载" panel shown as a TYPE_APPLICATION_OVERLAY window. Plain
 * Android views (no FlutterView): attaching a FlutterView to an overlay window
 * proved unreliable on some devices (transparent SurfaceView, dead touch).
 * Thumbnails load off the main thread with the webview cookie jar; the chosen
 * indices are handed back through [onResult].
 *
 * Supports long-press fullscreen preview for images and videos (default muted).
 * When [stickyPreview] is false, previews are peek-and-pop (releasing finger closes).
 * When [stickyPreview] is true, previews are persistent (tap to close).
 */
class SelectPanelView(
    context: Context,
    private val stickyPreview: Boolean = false,
    private val onResult: (List<Int>?) -> Unit,
) : FrameLayout(context) {

    companion object {
        const val TAG = "V16SEL"
        private const val COLS = 3
        private const val TARGET_PX = 300
    }

    private class ChevronView(context: Context, private val isLeft: Boolean) : View(context) {
        private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0x66000000
            style = Paint.Style.FILL
        }
        private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.STROKE
            strokeWidth = 2.8f * resources.displayMetrics.density
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        private val path = Path()

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val w = width.toFloat()
            val h = height.toFloat()
            val cx = w / 2f
            val cy = h / 2f
            val radius = Math.min(w, h) / 2f
            canvas.drawCircle(cx, cy, radius, bgPaint)

            path.reset()
            val arrowHalfW = radius * 0.22f
            val arrowHalfH = radius * 0.40f
            if (isLeft) {
                path.moveTo(cx + arrowHalfW, cy - arrowHalfH)
                path.lineTo(cx - arrowHalfW, cy)
                path.lineTo(cx + arrowHalfW, cy + arrowHalfH)
            } else {
                path.moveTo(cx - arrowHalfW, cy - arrowHalfH)
                path.lineTo(cx + arrowHalfW, cy)
                path.lineTo(cx - arrowHalfW, cy + arrowHalfH)
            }
            canvas.drawPath(path, strokePaint)
        }
    }

    private class PlayPauseView(context: Context) : View(context) {
        var isPlaying: Boolean = false
            set(value) {
                field = value
                invalidate()
            }

        private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.FILL
        }
        private val path = Path()

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val w = width.toFloat()
            val h = height.toFloat()
            val cx = w / 2f
            val cy = h / 2f
            val s = Math.min(w, h)

            if (isPlaying) {
                val barW = s * 0.16f
                val barH = s * 0.52f
                val gap = s * 0.16f
                val top = cy - barH / 2f
                val bottom = cy + barH / 2f
                val corner = barW / 3f

                val left1 = cx - gap / 2f - barW
                val right1 = cx - gap / 2f
                canvas.drawRoundRect(left1, top, right1, bottom, corner, corner, fillPaint)

                val left2 = cx + gap / 2f
                val right2 = cx + gap / 2f + barW
                canvas.drawRoundRect(left2, top, right2, bottom, corner, corner, fillPaint)
            } else {
                path.reset()
                val triW = s * 0.44f
                val triH = s * 0.48f
                val left = cx - triW * 0.42f
                val right = cx + triW * 0.58f
                val top = cy - triH / 2f
                val bottom = cy + triH / 2f
                path.moveTo(left, top)
                path.lineTo(right, cy)
                path.lineTo(left, bottom)
                path.close()
                canvas.drawPath(path, fillPaint)
            }
        }
    }

    private class Cell(
        val thumb: String,
        val url: String,
        val videoUrl: String?,
        val video: Boolean,
        val saved: Boolean,
    )

    private val main = Handler(Looper.getMainLooper())
    private val pool = Executors.newFixedThreadPool(6)
    private val cells = ArrayList<Cell>()
    private val selected = LinkedHashSet<Int>()
    private val shimmers = ArrayList<View>()
    private val syncers = ArrayList<() -> Unit>()
    private var shimmerAnim: ValueAnimator? = null
    private var finished = false

    private lateinit var countLabel: TextView
    private lateinit var allBtn: TextView
    private lateinit var downloadBtn: TextView
    private lateinit var grid: GridLayout
    private lateinit var savedBanner: TextView

    // Fullscreen preview components
    private var previewOverlay: FrameLayout? = null
    private var previewImage: ImageView? = null
    private var previewTexture: TextureView? = null
    private var previewProgress: ProgressBar? = null
    private var previewTitle: TextView? = null
    private var previewCloseBtn: TextView? = null
    private var mediaPlayer: MediaPlayer? = null
    private var previewIndex = -1
    private var previewOpenedAt = 0L

    // Navigation and video control components
    private var prevArrowBtn: View? = null
    private var nextArrowBtn: View? = null
    private var videoControlBar: LinearLayout? = null
    private var playPauseBtn: PlayPauseView? = null
    private var videoSeekBar: SeekBar? = null
    private var videoTimeText: TextView? = null
    private var isTrackingTouch = false

    private val isStickyPreview: Boolean
        get() = try {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            if (prefs.contains("flutter.bubblePreviewSticky")) {
                prefs.getBoolean("flutter.bubblePreviewSticky", false)
            } else {
                stickyPreview
            }
        } catch (_: Exception) { stickyPreview }

    init {
        setBackgroundColor(0x99000000.toInt())
        isClickable = true
        isFocusable = true
        isFocusableInTouchMode = true
        setOnClickListener { finish(null) }
        addView(
            buildSheet(),
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM)
        )
        addView(
            buildPreviewOverlay(),
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        )
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        requestFocus()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BACK) {
            if (event.action == KeyEvent.ACTION_UP) {
                if (previewOverlay?.visibility == View.VISIBLE) {
                    hidePreview()
                    return true
                }
                finish(null)
                return true
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (!isStickyPreview && previewOverlay?.visibility == View.VISIBLE) {
            if (ev.actionMasked == MotionEvent.ACTION_UP || ev.actionMasked == MotionEvent.ACTION_CANCEL) {
                hidePreview()
                return true
            }
        }
        return super.dispatchTouchEvent(ev)
    }

    fun setItems(items: List<Any?>) {
        cells.clear()
        for (raw in items) {
            val m = raw as? Map<*, *> ?: continue
            val thumb = m["thumb"] as? String ?: ""
            cells.add(
                Cell(
                    thumb = thumb,
                    url = m["url"] as? String ?: thumb,
                    videoUrl = m["videoUrl"] as? String,
                    video = m["video"] as? Boolean ?: false,
                    saved = m["saved"] as? Boolean ?: false,
                )
            )
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

        savedBanner = TextView(context).apply {
            text = "此帖子已下载过，可勾选补下缺失的"
            setTextColor(0xFFFFB26A.toInt())
            textSize = 12f
            setPadding(0, 0, 0, dp(6))
            visibility = View.GONE
        }
        sheet.addView(savedBanner)

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

    private fun buildPreviewOverlay(): View {
        val overlay = FrameLayout(context).apply {
            setBackgroundColor(0xF4000000.toInt())
            visibility = View.GONE
            isClickable = true
            setOnClickListener {
                if (!isStickyPreview) {
                    hidePreview()
                } else {
                    if (SystemClock.uptimeMillis() - previewOpenedAt > 400L) {
                        hidePreview()
                    }
                }
            }
        }

        val contentContainer = FrameLayout(context)
        overlay.addView(
            contentContainer,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        )

        previewImage = ImageView(context).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        contentContainer.addView(
            previewImage,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER)
        )

        previewTexture = TextureView(context).apply {
            visibility = View.GONE
        }
        contentContainer.addView(
            previewTexture,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER)
        )

        val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true
            override fun onFling(
                e1: MotionEvent?,
                e2: MotionEvent,
                velocityX: Float,
                velocityY: Float
            ): Boolean {
                if (e1 == null) return false
                val diffX = e2.x - e1.x
                val diffY = e2.y - e1.y
                if (Math.abs(diffX) > Math.abs(diffY) && Math.abs(diffX) > dp(36) && Math.abs(velocityX) > 150) {
                    if (diffX < 0) {
                        if (previewIndex < cells.size - 1) {
                            showPreview(previewIndex + 1)
                            return true
                        }
                    } else {
                        if (previewIndex > 0) {
                            showPreview(previewIndex - 1)
                            return true
                        }
                    }
                }
                return false
            }
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                if (previewIndex in cells.indices && cells[previewIndex].video) {
                    togglePlayPause()
                    return true
                }
                if (isStickyPreview && SystemClock.uptimeMillis() - previewOpenedAt > 400L) {
                    hidePreview()
                    return true
                }
                return false
            }
        })
        contentContainer.setOnTouchListener { _, event ->
            gestureDetector.onTouchEvent(event)
            true
        }

        // Navigation arrows (custom drawn for exact geometric centering)
        prevArrowBtn = ChevronView(context, isLeft = true).apply {
            visibility = View.GONE
            setOnClickListener {
                if (previewIndex > 0) showPreview(previewIndex - 1)
            }
        }
        overlay.addView(
            prevArrowBtn,
            LayoutParams(dp(44), dp(44), Gravity.CENTER_VERTICAL or Gravity.START).apply {
                marginStart = dp(12)
            }
        )

        nextArrowBtn = ChevronView(context, isLeft = false).apply {
            visibility = View.GONE
            setOnClickListener {
                if (previewIndex < cells.size - 1) showPreview(previewIndex + 1)
            }
        }
        overlay.addView(
            nextArrowBtn,
            LayoutParams(dp(44), dp(44), Gravity.CENTER_VERTICAL or Gravity.END).apply {
                marginEnd = dp(12)
            }
        )

        previewProgress = ProgressBar(context).apply {
            visibility = View.GONE
        }
        overlay.addView(
            previewProgress,
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER)
        )

        val topBar = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(28), dp(16), dp(16))
        }
        previewTitle = TextView(context).apply {
            setTextColor(Color.WHITE)
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
        }
        topBar.addView(
            previewTitle,
            LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
        )

        val closeBtn = TextView(context).apply {
            text = "✕"
            setTextColor(Color.WHITE)
            textSize = 20f
            setPadding(dp(12), dp(8), dp(12), dp(8))
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0x55000000)
            }
            setOnClickListener { hidePreview() }
        }
        previewCloseBtn = closeBtn
        topBar.addView(closeBtn)

        overlay.addView(
            topBar,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.TOP)
        )

        // Video control bar
        val bar = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(6), dp(12), dp(6))
            visibility = View.GONE
            background = GradientDrawable().apply {
                cornerRadius = dp(24).toFloat()
                setColor(0x99000000.toInt())
            }
        }
        playPauseBtn = PlayPauseView(context).apply {
            setOnClickListener { togglePlayPause() }
        }
        bar.addView(playPauseBtn, LinearLayout.LayoutParams(dp(36), dp(36)))

        videoSeekBar = SeekBar(context).apply {
            max = 1000
            progressTintList = ColorStateList.valueOf(0xFFFF5340.toInt())
            thumbTintList = ColorStateList.valueOf(0xFFFF5340.toInt())
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                    if (fromUser) {
                        val mp = mediaPlayer
                        val total = mp?.duration ?: 0
                        if (total > 0) {
                            val targetMs = (progress.toLong() * total / 1000L).toInt()
                            videoTimeText?.text = "${formatTime(targetMs)} / ${formatTime(total)}"
                        }
                    }
                }
                override fun onStartTrackingTouch(seekBar: SeekBar?) {
                    isTrackingTouch = true
                }
                override fun onStopTrackingTouch(seekBar: SeekBar?) {
                    val mp = mediaPlayer
                    val total = mp?.duration ?: 0
                    if (mp != null && total > 0 && seekBar != null) {
                        val targetMs = (seekBar.progress.toLong() * total / 1000L).toInt()
                        try { mp.seekTo(targetMs) } catch (_: Exception) {}
                    }
                    isTrackingTouch = false
                }
            })
        }
        bar.addView(videoSeekBar, LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))

        videoTimeText = TextView(context).apply {
            setTextColor(Color.WHITE)
            textSize = 11f
            text = "00:00 / 00:00"
            setPadding(dp(6), 0, dp(4), 0)
        }
        bar.addView(videoTimeText, LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))

        videoControlBar = bar
        overlay.addView(
            bar,
            LayoutParams(LayoutParams.MATCH_PARENT, dp(48), Gravity.BOTTOM).apply {
                setMargins(dp(16), 0, dp(16), dp(32))
            }
        )

        previewOverlay = overlay
        return overlay
    }

    private fun render() {
        grid.removeAllViews()
        syncers.clear()
        shimmers.clear()
        val anySaved = cells.any { it.saved }
        savedBanner.visibility = if (anySaved) View.VISIBLE else View.GONE
        val cell = (resources.displayMetrics.widthPixels - dp(28) - dp(8) * (COLS - 1)) / COLS
        val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
        val longPressTimeout = ViewConfiguration.getLongPressTimeout().toLong()

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

            // Shimmer placeholder while the thumbnail is still downloading.
            val shimmer = View(context).apply {
                background = GradientDrawable(
                    GradientDrawable.Orientation.TL_BR,
                    intArrayOf(0xFF3A3937.toInt(), 0xFF4A4846.toInt(), 0xFF3A3937.toInt()),
                ).apply { cornerRadius = dp(10).toFloat() }
                alpha = 0.6f
            }
            box.addView(shimmer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            shimmers.add(shimmer)
            startShimmer()

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
            if (cells[i].saved) {
                val tag = TextView(context).apply {
                    text = "已存"
                    setTextColor(Color.WHITE)
                    textSize = 10f
                    gravity = Gravity.CENTER
                    background = GradientDrawable().apply {
                        cornerRadius = dp(4).toFloat()
                        setColor(0xCC2E7D32.toInt())
                    }
                }
                box.addView(
                    tag,
                    LayoutParams(dp(34), dp(18), Gravity.TOP or Gravity.START)
                        .apply { setMargins(dp(6), dp(6), 0, 0) }
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
            syncers.add(::sync)

            var downX = 0f
            var downY = 0f
            var isLongPress = false
            val longPressRunnable = Runnable {
                isLongPress = true
                box.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                showPreview(i)
            }

            box.setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        isLongPress = false
                        downX = event.x
                        downY = event.y
                        main.postDelayed(longPressRunnable, longPressTimeout)
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        if (hypot(event.x - downX, event.y - downY) > touchSlop) {
                            main.removeCallbacks(longPressRunnable)
                        }
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        main.removeCallbacks(longPressRunnable)
                        if (isLongPress) {
                            if (!isStickyPreview) {
                                hidePreview()
                            }
                        } else {
                            if (!selected.remove(i)) selected.add(i)
                            sync()
                            updateFooter()
                        }
                        true
                    }
                    MotionEvent.ACTION_CANCEL -> {
                        main.removeCallbacks(longPressRunnable)
                        if (isLongPress && !isStickyPreview) {
                            hidePreview()
                        }
                        true
                    }
                    else -> false
                }
            }

            grid.addView(box)
            loadThumb(cells[i].thumb, iv, shimmer)
        }
        updateFooter()
    }

    private val updateProgressRunnable = object : Runnable {
        override fun run() {
            val mp = mediaPlayer
            if (mp != null && !isTrackingTouch) {
                try {
                    val current = mp.currentPosition
                    val total = mp.duration
                    if (total > 0) {
                        videoSeekBar?.progress = ((current.toLong() * 1000L) / total).toInt()
                        videoTimeText?.text = "${formatTime(current)} / ${formatTime(total)}"
                    }
                } catch (_: Exception) {}
            }
            if (previewIndex != -1 && previewOverlay?.visibility == View.VISIBLE) {
                main.postDelayed(this, 250L)
            }
        }
    }

    private fun formatTime(ms: Int): String {
        val totalSec = (ms / 1000).coerceAtLeast(0)
        val m = totalSec / 60
        val s = totalSec % 60
        return String.format(Locale.US, "%02d:%02d", m, s)
    }

    private fun togglePlayPause() {
        val mp = mediaPlayer ?: return
        try {
            if (mp.isPlaying) {
                mp.pause()
                playPauseBtn?.isPlaying = false
            } else {
                mp.start()
                playPauseBtn?.isPlaying = true
            }
        } catch (_: Exception) {}
    }

    private fun showPreview(index: Int) {
        if (index !in cells.indices) return
        previewIndex = index
        previewOpenedAt = SystemClock.uptimeMillis()
        val cell = cells[index]
        previewTitle?.text = if (cell.video) {
            "视频预览 (${index + 1}/${cells.size})"
        } else {
            "大图预览 (${index + 1}/${cells.size})"
        }
        previewCloseBtn?.visibility = if (isStickyPreview) View.VISIBLE else View.GONE
        prevArrowBtn?.visibility = if (isStickyPreview && index > 0) View.VISIBLE else View.GONE
        nextArrowBtn?.visibility = if (isStickyPreview && index < cells.size - 1) View.VISIBLE else View.GONE
        previewOverlay?.visibility = View.VISIBLE
        previewProgress?.visibility = View.VISIBLE

        releasePlayer()

        if (cell.video) {
            videoControlBar?.visibility = if (isStickyPreview) View.VISIBLE else View.GONE
            playPauseBtn?.isPlaying = true
            videoSeekBar?.progress = 0
            videoTimeText?.text = "00:00 / 00:00"
            previewImage?.visibility = View.GONE
            previewTexture?.visibility = View.VISIBLE
            val videoTarget = cell.videoUrl?.takeIf { it.isNotEmpty() } ?: cell.url
            playVideo(videoTarget)
            main.removeCallbacks(updateProgressRunnable)
            main.post(updateProgressRunnable)
        } else {
            videoControlBar?.visibility = View.GONE
            main.removeCallbacks(updateProgressRunnable)
            previewTexture?.visibility = View.GONE
            previewImage?.visibility = View.VISIBLE
            loadImage(cell.url, cell.thumb)
        }
    }

    private fun playVideo(videoUrl: String) {
        val texture = previewTexture ?: return
        fun startMp(surfaceTexture: SurfaceTexture) {
            try {
                val mp = MediaPlayer().apply {
                    setSurface(android.view.Surface(surfaceTexture))
                    setVolume(0f, 0f) // Muted by default for overlay preview
                    isLooping = true
                    val headers = HashMap<String, String>()
                    android.webkit.CookieManager.getInstance().getCookie(videoUrl)
                        ?.takeIf { it.isNotEmpty() }
                        ?.let { headers["Cookie"] = it }
                    headers["User-Agent"] =
                        "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36"
                    setDataSource(context, Uri.parse(videoUrl), headers)
                    setOnPreparedListener {
                        if (previewIndex != -1 && previewOverlay?.visibility == View.VISIBLE) {
                            previewProgress?.visibility = View.GONE
                            start()
                        }
                    }
                    setOnErrorListener { _, what, extra ->
                        Log.w(TAG, "MediaPlayer preview error: what=$what extra=$extra")
                        previewProgress?.visibility = View.GONE
                        true
                    }
                    prepareAsync()
                }
                mediaPlayer = mp
            } catch (e: Exception) {
                Log.e(TAG, "playVideo failed: $e")
                previewProgress?.visibility = View.GONE
            }
        }

        if (texture.isAvailable) {
            startMp(texture.surfaceTexture!!)
        } else {
            texture.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(st: SurfaceTexture, width: Int, height: Int) {
                    startMp(st)
                }
                override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, width: Int, height: Int) {}
                override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                    releasePlayer()
                    return true
                }
                override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
            }
        }
    }

    private fun loadImage(url: String, thumbUrl: String) {
        val target = previewImage ?: return
        target.setImageBitmap(null)
        val maxDim = resources.displayMetrics.widthPixels.coerceAtLeast(resources.displayMetrics.heightPixels)

        pool.execute {
            var bmp: Bitmap? = null
            try {
                val targetUrl = url.ifEmpty { thumbUrl }
                val conn = URL(targetUrl).openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 12000
                conn.instanceFollowRedirects = true
                runCatching { android.webkit.CookieManager.getInstance().getCookie(targetUrl) }
                    .getOrNull()?.takeIf { it.isNotEmpty() }
                    ?.let { conn.setRequestProperty("Cookie", it) }
                conn.setRequestProperty(
                    "Accept",
                    "image/webp,image/apng,image/*,*/*;q=0.8"
                )
                conn.connect()
                if (conn.responseCode in 200..299) {
                    val bytes = conn.inputStream.use { it.readBytes() }
                    bmp = decodeSampled(bytes, maxDim)
                }
                conn.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "loadImage failed: ${e.javaClass.simpleName}")
            }
            val resBmp = bmp
            main.post {
                if (previewIndex != -1 && previewOverlay?.visibility == View.VISIBLE) {
                    previewProgress?.visibility = View.GONE
                    if (resBmp != null) {
                        target.setImageBitmap(resBmp)
                    }
                }
            }
        }
    }

    private fun hidePreview() {
        previewIndex = -1
        releasePlayer()
        previewOverlay?.visibility = View.GONE
        previewImage?.setImageBitmap(null)
        videoControlBar?.visibility = View.GONE
    }

    private fun releasePlayer() {
        main.removeCallbacks(updateProgressRunnable)
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
        } catch (_: Exception) {}
        mediaPlayer = null
    }

    /// Pulsing placeholder animation shared by every pending thumbnail.
    private fun startShimmer() {
        if (shimmerAnim != null) return
        shimmerAnim = ValueAnimator.ofFloat(0.35f, 0.95f).apply {
            duration = 550
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            addUpdateListener { anim ->
                val v = anim.animatedValue as Float
                for (s in shimmers) s.alpha = v
            }
            start()
        }
    }

    private fun updateFooter() {
        val total = cells.size
        countLabel.text = "已选 ${selected.size}/$total"
        allBtn.text = if (total > 0 && selected.size == total) "取消全选" else "全选"
        downloadBtn.text = "下载 (${selected.size})"
        downloadBtn.alpha = if (selected.isEmpty()) 0.5f else 1f
    }

    private fun toggleAll() {
        if (selected.size == cells.size) {
            selected.clear()
        } else {
            selected.clear()
            selected.addAll(cells.indices)
        }
        for (s in syncers) s()
        updateFooter()
    }

    private fun loadThumb(url: String, target: ImageView, shimmer: View) {
        if (url.isEmpty()) {
            shimmer.visibility = View.GONE
            return
        }
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
                Log.w(
                    TAG,
                    "thumb failed: ${e.javaClass.simpleName} host=" +
                        LogSanitizer.hostPath(url),
                )
            }
            val bmp = bitmap
            main.post {
                if (bmp != null && target.isAttachedToWindow) {
                    target.setImageBitmap(bmp)
                    shimmer.visibility = View.GONE
                    shimmers.remove(shimmer)
                }
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
        hidePreview()
        main.post { onResult(result) }
    }

    fun release() {
        hidePreview()
        shimmerAnim?.cancel()
        shimmerAnim = null
        pool.shutdownNow()
    }
}