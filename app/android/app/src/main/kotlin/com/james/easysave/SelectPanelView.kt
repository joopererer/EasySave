package com.james.easysave

import android.animation.ValueAnimator
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.Format
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
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
import android.text.InputType
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.ScrollView
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
 * Thumbnails load off the main thread using cookie-free policy declarations; the chosen
 * indices are handed back through [onResult].
 *
 * Supports long-press fullscreen preview for images and videos (default muted).
 * When [stickyPreview] is false, previews are peek-and-pop (releasing finger closes).
 * When [stickyPreview] is true, previews are persistent (tap to close).
 */
class SelectPanelView(
    context: Context,
    private val stickyPreview: Boolean = false,
    private val onPolicyRejected: (String, String, String, String) -> Unit = { _, _, _, _ -> },
    private val onOpenPreview: () -> Unit = {},
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

    private class HoldProgressView(context: Context) : View(context) {
        var progress = 0f
            set(value) { field = value; invalidate() }
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 4f * resources.displayMetrics.density
            strokeCap = Paint.Cap.ROUND
        }
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xB3222222.toInt() }
            canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), 12f, 12f, backgroundPaint)
            val numeral = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE; textAlign = Paint.Align.CENTER
                textSize = height * 0.44f; typeface = Typeface.DEFAULT_BOLD
            }
            canvas.drawText(holdCountdown(progress).toString(), width / 2f,
                height / 2f - (numeral.ascent() + numeral.descent()) / 2f, numeral)
            val inset = paint.strokeWidth / 2f + width * 0.08f
            paint.color = 0x66FFFFFF
            canvas.drawArc(inset, inset, width - inset, height - inset, 0f, 360f, false, paint)
            paint.color = Color.WHITE
            canvas.drawArc(inset, inset, width - inset, height - inset, -90f, 360f * progress, false, paint)
        }
    }

    private class Cell(
        val thumbRequest: NativeMediaRequest,
        val imageRequest: NativeMediaRequest,
        val videoRequest: NativeMediaRequest,
        val thumbFallbacks: List<NativeMediaRequest>,
        val imageFallbacks: List<NativeMediaRequest>,
        val video: Boolean,
        val live: Boolean,
        val saved: Boolean,
        val openOnHold: Boolean,
        /** MediaStore id of the already-saved copy, when the album has it. */
        val savedMediaId: String?,
    )

    private val main = Handler(Looper.getMainLooper())
    private val pool = Executors.newFixedThreadPool(2)
    private val cells = ArrayList<Cell>()
    private val selected = LinkedHashSet<Int>()
    private val shimmers = ArrayList<View>()
    private val syncers = ArrayList<() -> Unit>()
    private var shimmerAnim: ValueAnimator? = null
    private var finished = false

    // Thumbnails cost mobile data, so they stay off until the user asks.
    private var showThumbs = false
    private lateinit var specInput: EditText
    private lateinit var specHint: TextView
    private lateinit var thumbToggle: TextView

    private lateinit var countLabel: TextView
    private lateinit var allBtn: TextView
    private lateinit var downloadBtn: TextView
    private lateinit var grid: GridLayout
    private lateinit var savedBanner: TextView
    private lateinit var postTitleView: TextView
    private lateinit var aiBadge: TextView
    private var aiDialog: AlertDialog? = null

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        postTitleView.maxWidth = (View.MeasureSpec.getSize(widthMeasureSpec) - dp(80)).coerceAtLeast(0)
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }

    fun setPostMetadata(title: String?, label: Map<*, *>?) {
        aiDialog?.dismiss()
        postTitleView.text = title?.takeIf { it.isNotBlank() } ?: "选择要下载的内容"
        val text = (label?.get("text") as? String)?.takeIf { it.isNotBlank() }
        aiBadge.visibility = if (text == null) View.GONE else View.VISIBLE
        aiBadge.setOnClickListener(if (text == null) null else OnClickListener {
            val source = when (label?.get("source")) {
                "platform" -> "平台识别"
                "author" -> "作者声明"
                else -> "来源未知"
            }
            val content = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(24), dp(12), dp(24), dp(12))
                for (line in listOf(text, source, "来自平台标注，仅供参考")) {
                    addView(TextView(context).apply {
                        this.text = line
                        setTextIsSelectable(true)
                        setPadding(0, dp(4), 0, dp(4))
                    })
                }
            }
            aiDialog = AlertDialog.Builder(context).setTitle("AI 标注").setView(content)
                .setPositiveButton("关闭") { dialog, _ -> dialog.dismiss() }.create().also {
                    if (context !is Activity) {
                        val overlayType = if (android.os.Build.VERSION.SDK_INT >= 26) {
                            android.view.WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                        } else {
                            @Suppress("DEPRECATION")
                            android.view.WindowManager.LayoutParams.TYPE_PHONE
                        }
                        it.window?.setType(overlayType)
                    }
                    it.show()
                }
        })
    }

    // Fullscreen preview components
    private var previewOverlay: FrameLayout? = null
    private var previewImage: ImageView? = null
    private var previewTexture: TextureView? = null
    private var previewProgress: ProgressBar? = null
    private var previewTitle: TextView? = null
    private var previewCloseBtn: TextView? = null
    private var mediaPlayer: ExoPlayer? = null
    private val playerSessions = PreviewSessions<ExoPlayer> {
        it.clearVideoSurface()
        it.release()
    }
    private var previewIndex = -1
    private var previewGeneration = 0
    private var previewFrameTimeout: Runnable? = null
    private var previewOpenedAt = 0L
    private val holdToOpen = HoldToOpen()
    private var holdAnimator: ValueAnimator? = null
    private var holdIndicator: HoldProgressView? = null
    private var holdTrigger: Runnable? = null
    private var holdTick: Runnable? = null
    private var holdPreview = false

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
            LayoutParams(LayoutParams.MATCH_PARENT, (resources.displayMetrics.heightPixels * 0.72).toInt(), Gravity.BOTTOM)
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
        if ((!isStickyPreview || holdPreview) && previewOverlay?.visibility == View.VISIBLE) {
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
            fun request(key: String) = NativeMediaRequest(
                m[key] as? Map<*, *>, key, onPolicyRejected,
            )
            fun fallbackRequests(key: String, field: String) =
                (m[key] as? List<*>)?.map {
                    NativeMediaRequest(it as? Map<*, *>, field, onPolicyRejected)
                } ?: emptyList()
            cells.add(
                Cell(
                    thumbRequest = request("thumbRequest"),
                    imageRequest = request("imageRequest"),
                    videoRequest = request("videoRequest"),
                    thumbFallbacks = fallbackRequests("thumbFallbacks", "thumbRequest"),
                    imageFallbacks = fallbackRequests("imageFallbacks", "imageRequest"),
                    video = m["video"] as? Boolean ?: false,
                    live = m["live"] as? Boolean ?: false,
                    saved = m["saved"] as? Boolean ?: false,
                    openOnHold = m["openOnHold"] as? Boolean ?: false,
                    savedMediaId = (m["savedMediaId"] as? String)?.takeIf { it.isNotBlank() },
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

        val postHeader = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(4), 0, dp(4))
        }
        postTitleView = TextView(context).apply {
            text = "选择要下载的内容"
            setTextColor(Color.WHITE)
            textSize = 16f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        postHeader.addView(postTitleView, LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        aiBadge = TextView(context).apply {
            text = "AI"
            textSize = 11f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            setPadding(dp(4), 0, dp(4), 0)
            background = GradientDrawable().apply {
                setColor(Color.TRANSPARENT)
                setStroke(dp(2), 0xFFFF6A3D.toInt())
                cornerRadius = dp(8).toFloat()
            }
            contentDescription = "AI 标注"
            visibility = View.GONE
        }
        postHeader.addView(aiBadge, LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
            leftMargin = dp(4)
        })
        sheet.addView(postHeader)

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

        // Number entry: type the item numbers chosen elsewhere (e.g. 1,3,5-8)
        // instead of loading thumbnails to tap them.
        val specRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        specInput = EditText(context).apply {
            hint = "输入编号，如 1,3,5-8"
            setHintTextColor(0x66FFFFFF)
            setTextColor(Color.WHITE)
            textSize = 14f
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT
            imeOptions = EditorInfo.IME_ACTION_DONE
            setPadding(dp(12), dp(8), dp(12), dp(8))
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(0xFF2A2928.toInt())
            }
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_DONE) {
                    applySpec()
                    true
                } else false
            }
        }
        specRow.addView(
            specInput,
            LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT).apply { weight = 1f }
        )
        specRow.addView(
            TextView(context).apply {
                text = "应用"
                setTextColor(0xFFFF6A3D.toInt())
                textSize = 14f
                setPadding(dp(14), dp(8), dp(6), dp(8))
                setOnClickListener { applySpec() }
            }
        )
        sheet.addView(specRow)

        val subRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(4), 0, dp(4))
        }
        specHint = TextView(context).apply {
            setTextColor(0x99FFFFFF.toInt())
            textSize = 12f
        }
        subRow.addView(
            specHint,
            LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT).apply { weight = 1f }
        )
        thumbToggle = TextView(context).apply {
            text = "显示预览图（耗流量）"
            setTextColor(0xFFFF6A3D.toInt())
            textSize = 12f
            setPadding(dp(8), dp(4), 0, dp(4))
            setOnClickListener {
                showThumbs = !showThumbs
                text = if (showThumbs) "隐藏预览图" else "显示预览图（耗流量）"
                render()
            }
        }
        subRow.addView(thumbToggle)
        sheet.addView(subRow)

        grid = GridLayout(context).apply { columnCount = COLS }
        val scroll = ScrollView(context).apply {
            isFillViewport = false
            addView(grid, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        }
        sheet.addView(
            scroll,
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
            addOnLayoutChangeListener { view, _, _, _, _, _, _, _, _ ->
                val mp = mediaPlayer ?: return@addOnLayoutChangeListener
                fitVideoToView(mp.videoSize.width, mp.videoSize.height, view.width, view.height)
            }
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
                if (previewIndex in cells.indices && previewUsesVideo(cells[previewIndex].video, cells[previewIndex].live)) {
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
            indeterminateTintList = ColorStateList.valueOf(0xFFFFFFFF.toInt())
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0x99000000.toInt())
            }
            setPadding(dp(6), dp(6), dp(6), dp(6))
        }
        overlay.addView(
            previewProgress,
            LayoutParams(dp(48), dp(48), Gravity.CENTER)
        )
        holdIndicator = HoldProgressView(context).apply {
            visibility = View.GONE
        }
        overlay.addView(holdIndicator, LayoutParams(dp(48), dp(48), Gravity.CENTER).apply {
            topMargin = dp(80)
        })

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
                        val total = mp?.duration?.toInt() ?: 0
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
                    val total = mp?.duration?.toInt() ?: 0
                    if (mp != null && total > 0 && seekBar != null) {
                        val targetMs = (seekBar.progress.toLong() * total / 1000L).toInt()
                        try { mp.seekTo(targetMs.toLong()) } catch (_: Exception) {}
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
        NativeThumbBitmaps.configure(context)
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
            val memory = if (showThumbs && cells[i].thumbRequest.canUseMemory())
                NativeThumbBitmaps.get(cells[i].thumbRequest.bitmapKey(cell)) else null
            if (memory != null) {
                iv.setImageBitmap(memory)
                NativeLog.i("ThumbLoad", "event=memory_hit queue=read waitMs=0 ioMs=0 ms=0 key=${cells[i].thumbRequest.cacheLabel}")
            }

            // Shimmer placeholder while the thumbnail is still downloading.
            val shimmer = View(context).apply {
                background = GradientDrawable(
                    GradientDrawable.Orientation.TL_BR,
                    intArrayOf(0xFF3A3937.toInt(), 0xFF4A4846.toInt(), 0xFF3A3937.toInt()),
                ).apply { cornerRadius = dp(10).toFloat() }
                alpha = 0.6f
            }
            box.addView(shimmer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            if (memory == null && showThumbs && (listOf(cells[i].thumbRequest) + cells[i].thumbFallbacks).any { !it.requiresAppPreview }) {
                shimmers.add(shimmer)
                startShimmer()
            } else {
                shimmer.visibility = View.GONE
            }
            if (cells[i].thumbRequest.requiresAppPreview) {
                box.addView(TextView(context).apply {
                    text = "请在 App 内预览"
                    setTextColor(Color.WHITE)
                    textSize = 12f
                    gravity = Gravity.CENTER
                }, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            }

            // Item number (1-based), matching what the post shows. Large when
            // thumbnails are off, small badge when they are on.
            box.addView(
                TextView(context).apply {
                    text = "${i + 1}"
                    setTextColor(Color.WHITE)
                    typeface = Typeface.DEFAULT_BOLD
                    if (showThumbs) {
                        textSize = 11f
                        gravity = Gravity.CENTER
                        background = GradientDrawable().apply {
                            cornerRadius = dp(4).toFloat()
                            setColor(0x99000000.toInt())
                        }
                    } else {
                        textSize = 26f
                        gravity = Gravity.CENTER
                    }
                },
                if (showThumbs) {
                    LayoutParams(dp(26), dp(18), Gravity.BOTTOM or Gravity.END)
                        .apply { setMargins(0, 0, dp(6), dp(6)) }
                } else {
                    LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
                }
            )

            if (cells[i].live) {
                box.addView(TextView(context).apply {
                    text = "LIVE"
                    includeFontPadding = false
                    setTextColor(Color.WHITE)
                    textSize = 11f
                    setPadding(dp(6), dp(2), dp(6), dp(2))
                    background = GradientDrawable().apply {
                        cornerRadius = dp(6).toFloat()
                        setColor(0x8A000000.toInt())
                    }
                }, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT,
                    Gravity.BOTTOM or Gravity.START).apply { setMargins(dp(6), 0, 0, dp(6)) })
            } else if (cells[i].video) {
                box.addView(
                    TextView(context).apply {
                        text = "▶"
                        setTextColor(Color.WHITE)
                        textSize = 14f
                    },
                    LayoutParams(dp(26), dp(26), Gravity.BOTTOM or Gravity.START)
                        .apply { setMargins(dp(6), 0, 0, dp(6)) }
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
            if (memory == null && showThumbs && !cells[i].thumbRequest.requiresAppPreview) {
                // Start only visible cells. ScrollView layout creates all number
                // selectors, but offscreen selectors do not fetch or decode.
                var started = false
                var onScroll: android.view.ViewTreeObserver.OnScrollChangedListener? = null
                fun stopWatching() {
                    onScroll?.let { if (iv.viewTreeObserver.isAlive) iv.viewTreeObserver.removeOnScrollChangedListener(it) }
                }
                fun loadVisible() {
                    if (!started && iv.getGlobalVisibleRect(android.graphics.Rect())) {
                        started = true
                        stopWatching()
                        loadThumb(listOf(cells[i].thumbRequest) + cells[i].thumbFallbacks, iv, shimmer)
                    }
                }
                iv.post { loadVisible() }
                onScroll = android.view.ViewTreeObserver.OnScrollChangedListener { loadVisible() }
                iv.viewTreeObserver.addOnScrollChangedListener(onScroll)
                iv.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
                    override fun onViewAttachedToWindow(view: View) {}
                    override fun onViewDetachedFromWindow(view: View) { stopWatching() }
                })
            }
        }
        updateFooter()
    }

    private val updateProgressRunnable = object : Runnable {
        override fun run() {
            val mp = mediaPlayer
            if (mp != null && !isTrackingTouch) {
                try {
                    val current = mp.currentPosition.toInt()
                    val total = mp.duration.toInt()
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
                mp.play()
                playPauseBtn?.isPlaying = true
            }
        } catch (_: Exception) {}
    }

    private fun showPreview(index: Int) {
        if (index !in cells.indices) return
        cancelHoldPreview()
        previewIndex = index
        val generation = ++previewGeneration
        previewOpenedAt = SystemClock.uptimeMillis()
        val cell = cells[index]
        val playMotion = previewUsesVideo(cell.video, cell.live)
        val request = if (playMotion) cell.videoRequest else cell.imageRequest
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
        previewTitle?.setOnClickListener(null)

        if (cell.openOnHold) {
                holdPreview = true
                previewTexture?.visibility = View.GONE
                previewImage?.visibility = View.VISIBLE
                previewImage?.setImageBitmap(null)
                previewProgress?.visibility = View.GONE
                videoControlBar?.visibility = View.GONE
                previewCloseBtn?.visibility = View.GONE
                prevArrowBtn?.visibility = View.GONE
                nextArrowBtn?.visibility = View.GONE
                previewTitle?.text = "继续按住在 App 中打开"
                if ((listOf(cell.thumbRequest) + cell.thumbFallbacks).any { !it.requiresAppPreview }) {
                    loadImage(listOf(cell.thumbRequest) + cell.thumbFallbacks, generation)
                }
                val indicator = holdIndicator
                indicator?.visibility = View.VISIBLE
                holdToOpen.start(SystemClock.uptimeMillis())
                val trigger = Runnable {
                    if (holdToOpen.takeTrigger(SystemClock.uptimeMillis()) &&
                        previewCurrent(generation)) {
                        hidePreview()
                        onOpenPreview()
                    }
                }
                holdTrigger = trigger
                main.postDelayed(trigger, 3000L)
                val tick = object : Runnable {
                    override fun run() {
                        if (!previewCurrent(generation) || !holdPreview) return
                        indicator?.progress = holdToOpen.progress(SystemClock.uptimeMillis())
                        main.postDelayed(this, 50L)
                    }
                }
                holdTick = tick
                main.post(tick)
                return
        }
        if (request.requiresAppPreview) {
            if (cell.live) {
                showLiveStill(cell, generation)
                return
            }
            previewTexture?.visibility = View.GONE
            previewImage?.visibility = View.GONE
            previewProgress?.visibility = View.GONE
            videoControlBar?.visibility = View.GONE
            previewTitle?.text = "请在 App 内预览（点击打开 App）"
            previewTitle?.setOnClickListener {
                context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
                    context.startActivity(it)
                }
            }
            return
        }
        if (playMotion) {
            videoControlBar?.visibility = if (isStickyPreview) View.VISIBLE else View.GONE
            playPauseBtn?.isPlaying = true
            videoSeekBar?.progress = 0
            videoTimeText?.text = "00:00 / 00:00"
            previewImage?.visibility = View.VISIBLE
            previewImage?.setImageBitmap(null)
            previewTexture?.visibility = View.VISIBLE
            previewTexture?.alpha = 0f
            previewImage?.bringToFront()
            val poster = if (cell.live) listOf(cell.imageRequest) + cell.imageFallbacks
                else listOf(cell.thumbRequest) + cell.thumbFallbacks
            if (poster.any { !it.requiresAppPreview }) loadImage(poster, generation, keepProgress = true)
            playVideo(cell, generation)
            main.removeCallbacks(updateProgressRunnable)
            main.post(updateProgressRunnable)
        } else {
            videoControlBar?.visibility = View.GONE
            main.removeCallbacks(updateProgressRunnable)
            previewTexture?.visibility = View.GONE
            previewImage?.visibility = View.VISIBLE
            // A file the album already holds is opened from the album: no
            // network request, no thumbnail placeholder and no spinner. Only
            // items that are not saved locally go through the network path.
            val savedId = cell.savedMediaId
            if (cell.saved && !cell.video && savedId != null) {
                loadSavedImage(savedId, generation)
            } else {
                loadImage(listOf(cell.imageRequest) + cell.imageFallbacks, generation)
            }
        }
    }

    /**
     * Decode the already-saved album copy of an image for the fullscreen
     * preview. Runs off the main thread like [loadImage]; falls back to the
     * network request when MediaStore no longer serves the id.
     */
    private fun loadSavedImage(mediaId: String, generation: Int) {
        val target = previewImage ?: return
        val cell = cells.getOrNull(previewIndex)
        previewProgress?.visibility = View.GONE
        val maxDim = resources.displayMetrics.widthPixels.coerceAtLeast(resources.displayMetrics.heightPixels)
        pool.execute {
            val bitmap = runCatching {
                val id = mediaId.toLongOrNull() ?: return@runCatching null
                val uri = android.content.ContentUris.withAppendedId(
                    android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id
                )
                NativeLocalBitmap.decode(context, uri, maxDim)
            }.getOrNull()
            main.post {
                if (!previewCurrent(generation)) return@post
                if (bitmap != null) {
                    val parent = target.parent as? View
                    val fit = stillLetterbox(bitmap.width, bitmap.height,
                        parent?.width ?: target.width, parent?.height ?: target.height)
                    target.scaleType = ImageView.ScaleType.FIT_CENTER
                    if (fit != null) target.layoutParams = LayoutParams(fit.width, fit.height, Gravity.CENTER)
                    target.setImageBitmap(bitmap)
                } else if (cell != null) {
                    NativeLog.w(TAG, "local preview unavailable, using network")
                    previewProgress?.visibility = View.VISIBLE
                    loadImage(listOf(cell.imageRequest) + cell.imageFallbacks, generation)
                }
            }
        }
    }

    private fun previewCurrent(generation: Int) =
        previewGeneration == generation && previewOverlay?.visibility == View.VISIBLE

    private fun showLiveStill(cell: Cell, generation: Int, failed: Boolean = false) {
        if (!previewCurrent(generation)) return
        releasePlayer()
        previewImage?.setImageBitmap(null)
        previewTexture?.setTransform(Matrix())
        previewImage?.scaleType = ImageView.ScaleType.FIT_CENTER
        if (failed) previewTitle?.text = "视频加载失败，显示静态图"
        videoControlBar?.visibility = View.GONE
        previewTexture?.visibility = View.GONE
        previewImage?.visibility = View.VISIBLE
        val stills = if (cell.video && !cell.live) listOf(cell.thumbRequest) + cell.thumbFallbacks
            else listOf(cell.imageRequest) + cell.imageFallbacks
        if (stills.all { it.requiresAppPreview }) {
            previewProgress?.visibility = View.GONE
            previewTitle?.text = "请在 App 内预览（点击打开 App）"
            previewTitle?.setOnClickListener {
                context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
                    context.startActivity(it)
                }
            }
        } else {
            loadImage(stills, generation)
        }
    }

    private fun playVideo(cell: Cell, generation: Int) {
        pool.execute {
            val file = java.io.File(context.cacheDir, "policy_preview_${System.nanoTime()}.mp4")
            try {
                // All HTTPS headers and every redirect remain policy checked here.
                // ExoPlayer receives only a private local file, never cookies.
                cell.videoRequest.writeVideo(file)
            } catch (error: Exception) {
                file.delete()
                main.post {
                    if (!previewCurrent(generation)) return@post
                    NativeLog.i("PreviewPlayer", "event=error errorCode=SOURCE_DOWNLOAD_FAILED")
                    showLiveStill(cell, generation, failed = true)
                }
                return@execute
            }
            main.post {
                if (!previewCurrent(generation)) { file.delete(); return@post }
                previewVideoFile = file
                var mime = "unknown"
                var decoder = "unknown"
                var width = 0
                var height = 0
                var fallback = false
                val fallbackTrace = DecoderFallbackTrace()
                val (token, player) = playerSessions.begin {
                    val renderers = object : DefaultRenderersFactory(context) {
                        override fun getCodecAdapterFactory(): MediaCodecAdapter.Factory {
                            val delegate = super.getCodecAdapterFactory()
                            return MediaCodecAdapter.Factory { configuration ->
                                try { delegate.createAdapter(configuration) }
                                catch (error: Exception) {
                                    if (configuration.format.sampleMimeType?.startsWith("video/") == true) {
                                        fallbackTrace.initializationFailed(configuration.codecInfo.name)
                                    }
                                    throw error
                                }
                            }
                        }
                    }.setEnableDecoderFallback(true)
                    ExoPlayer.Builder(context, renderers).build()
                }
                mediaPlayer = player
                fun current() = previewCurrent(generation) && playerSessions.accepts(token, player)
                fun log(event: String, code: String = "none") {
                    if (!current()) return
                    fun safe(value: String) = value.take(120).replace(Regex("[^A-Za-z0-9_./-]"), "_")
                    NativeLog.i("PreviewPlayer", "event=$event generation=$token host=${cell.videoRequest.diagnosticHost} " +
                        "mime=${safe(mime)} width=$width height=$height decoder=${safe(decoder)} " +
                        "decoderFallback=$fallback fallbackEnabled=true errorCode=${safe(code)}")
                }
                fun failed(code: String) {
                    if (!current()) return
                    log("error", code)
                    // Invalidate first, unbind and release before displaying a still.
                    releasePlayer()
                    showLiveStill(cell, generation, failed = true)
                }
                player.addAnalyticsListener(object : AnalyticsListener {
                    override fun onVideoInputFormatChanged(eventTime: AnalyticsListener.EventTime,
                        format: Format, decoderReuseEvaluation: androidx.media3.exoplayer.DecoderReuseEvaluation?) {
                        if (!current()) return
                        mime = format.sampleMimeType ?: "unknown"
                        width = format.width.coerceAtLeast(0)
                        height = format.height.coerceAtLeast(0)
                        log("format")
                    }
                    override fun onVideoCodecError(eventTime: AnalyticsListener.EventTime, videoCodecError: Exception) {
                        if (!current()) return
                        fallbackTrace.codecFailed()
                        log("decoderError", "VIDEO_CODEC_ERROR")
                    }
                    override fun onVideoDecoderInitialized(eventTime: AnalyticsListener.EventTime,
                        decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
                        if (!current()) return
                        fallback = fallbackTrace.initialized(decoderName)
                        decoder = decoderName
                        log("decoderInitialized")
                    }
                })
                player.addListener(object : Player.Listener {
                    override fun onVideoSizeChanged(videoSize: VideoSize) {
                        if (!current()) return
                        width = videoSize.width
                        height = videoSize.height
                        fitVideoToView(width, height)
                    }
                    override fun onRenderedFirstFrame() {
                        if (!current()) return
                        log("firstFrame")
                        previewTexture?.alpha = 1f
                        previewFrameTimeout?.let { main.removeCallbacks(it) }
                        previewFrameTimeout = null
                        previewProgress?.visibility = View.GONE
                        previewImage?.visibility = View.GONE
                    }
                    override fun onPlayerError(error: PlaybackException) { failed(error.errorCodeName) }
                })
                try {
                    player.repeatMode = Player.REPEAT_MODE_ONE
                    player.volume = 0f
                    player.setVideoTextureView(previewTexture)
                    player.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
                    val timeout = Runnable { failed("ERROR_CODE_TIMEOUT") }
                    previewFrameTimeout = timeout
                    main.postDelayed(timeout, 15000L)
                    log("prepare")
                    player.prepare()
                    player.play()
                } catch (_: Exception) { failed("ERROR_CODE_UNSPECIFIED") }
            }
        }
    }

    private fun loadImage(requests: List<NativeMediaRequest>, generation: Int, keepProgress: Boolean = false) {
        val target = previewImage ?: return
        val cell = cells.getOrNull(previewIndex)
        val thumb = cell?.thumbRequest
        val pixels = (resources.displayMetrics.widthPixels - dp(28) - dp(8) * (COLS - 1)) / COLS
        val memory = if (thumb?.canUseMemory() == true) NativeThumbBitmaps.get(thumb.bitmapKey(pixels)) else null
        target.scaleType = ImageView.ScaleType.FIT_CENTER
        target.setImageBitmap(memory)
        val maxDim = resources.displayMetrics.widthPixels.coerceAtLeast(resources.displayMetrics.heightPixels)
        pool.execute {
            val (bmp, denied) = decodeFirstImage(requests, maxDim)
            val result = bmp
            main.post {
                if (previewCurrent(generation)) {
                    if (!keepProgress) previewProgress?.visibility = View.GONE
                    if (denied && !keepProgress) previewTitle?.text = "该资源地址不在允许范围内"
                    if (result != null) {
                        val parent = target.parent as? View
                        val fit = stillLetterbox(result.width, result.height,
                            parent?.width ?: target.width, parent?.height ?: target.height)
                        target.scaleType = ImageView.ScaleType.FIT_CENTER
                        if (fit != null) target.layoutParams = LayoutParams(fit.width, fit.height, Gravity.CENTER)
                        target.setImageBitmap(result)
                    }
                }
            }
        }
    }

    private fun cancelHoldPreview() {
        holdToOpen.cancel()
        holdTrigger?.let { main.removeCallbacks(it) }
        holdTrigger = null
        holdTick?.let { main.removeCallbacks(it) }
        holdTick = null
        holdAnimator?.cancel()
        holdAnimator = null
        holdIndicator?.visibility = View.GONE
        holdPreview = false
    }

    private fun hidePreview() {
        cancelHoldPreview()
        previewIndex = -1
        previewGeneration++
        releasePlayer()
        previewOverlay?.visibility = View.GONE
        previewImage?.setImageBitmap(null)
        videoControlBar?.visibility = View.GONE
        previewTexture?.setTransform(null)
    }

    /**
     * Letterbox the preview video.
     *
     * A TextureView always stretches its surface to its own bounds, so a 9:16
     * clip in a portrait overlay looked pulled out of shape. Scale it uniformly
     * to fit inside the visible area and let the overlay background fill the
     * rest. No-op until both the media and the view have a size.
     */
    private fun fitVideoToView(
        videoWidth: Int,
        videoHeight: Int,
        viewWidth: Int = previewTexture?.width ?: 0,
        viewHeight: Int = previewTexture?.height ?: 0,
    ) {
        val texture = previewTexture ?: return
        val fit = videoFitScale(videoWidth, videoHeight, viewWidth, viewHeight) ?: return
        val matrix = Matrix()
        matrix.setScale(
            fit.scaleX,
            fit.scaleY,
            viewWidth / 2f,
            viewHeight / 2f,
        )
        texture.setTransform(matrix)
    }

    private var previewVideoFile: java.io.File? = null

    private fun releasePlayer() {
        main.removeCallbacks(updateProgressRunnable)
        previewFrameTimeout?.let { main.removeCallbacks(it) }
        previewFrameTimeout = null
        playerSessions.close()
        mediaPlayer = null
        previewTexture?.surfaceTextureListener = null
        previewTexture?.setTransform(Matrix())
        previewTexture?.alpha = 0f
        previewImage?.scaleType = ImageView.ScaleType.FIT_CENTER
        previewImage?.imageMatrix = Matrix()
        previewImage?.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER)
        previewVideoFile?.delete()
        previewVideoFile = null
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

    /** Replace the selection with the numbers typed in [specInput]. */
    private fun applySpec() {
        val text = specInput.text.toString()
        if (text.isBlank()) return
        val total = cells.size
        val r = IndexSpec.parse(text, total)
        selected.clear()
        selected.addAll(r.indices)
        for (s in syncers) s()
        updateFooter()
        specHint.setTextColor(
            if (r.invalid || r.outOfRange) 0xFFFFB26A.toInt() else 0x99FFFFFF.toInt()
        )
        specHint.text = when {
            r.invalid -> "有无法识别的编号，共 $total 张"
            r.outOfRange -> "部分编号超出范围，共 $total 张"
            else -> "已选 ${r.indices.size} 项"
        }
        // Hide the keyboard so the download button is reachable.
        runCatching {
            val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE)
                as android.view.inputmethod.InputMethodManager
            imm.hideSoftInputFromWindow(specInput.windowToken, 0)
        }
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

    private fun loadThumb(requests: List<NativeMediaRequest>, target: ImageView, shimmer: View) {
        val pixels = target.width.takeIf { it > 0 } ?: dp(TARGET_PX)
        val first = requests.firstOrNull()
        val memory = if (first?.canUseMemory() == true) NativeThumbBitmaps.get(first.bitmapKey(pixels)) else null
        if (memory != null) {
            target.setImageBitmap(memory)
            shimmer.visibility = View.GONE
            shimmers.remove(shimmer)
            NativeLog.i("ThumbLoad", "event=memory_hit queue=read waitMs=0 ioMs=0 ms=0 key=${first?.cacheLabel}")
            return
        }
        fun display(bmp: Bitmap?, denied: Boolean) {
            main.post {
                if (target.isAttachedToWindow) {
                    if (bmp != null) target.setImageBitmap(bmp)
                    if (bmp == null && !denied) {
                        val box = target.parent as? FrameLayout
                        val retry = TextView(context).apply {
                            text = "加载失败，点击重试"
                            setTextColor(Color.WHITE)
                            textSize = 11f
                            gravity = Gravity.CENTER
                            setOnClickListener {
                                box?.removeView(this)
                                shimmer.visibility = View.VISIBLE
                                loadThumb(requests, target, shimmer)
                            }
                        }
                        box?.addView(retry, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
                    }
                    if (denied) {
                        target.setImageResource(android.R.drawable.ic_delete)
                        android.widget.Toast.makeText(context,
                            "该资源地址不在允许范围内", android.widget.Toast.LENGTH_SHORT).show()
                    }
                    shimmer.visibility = View.GONE
                    shimmers.remove(shimmer)
                }
            }
        }
        fun next(index: Int, denied: Boolean, retry: Boolean = true) {
            if (index >= requests.size) { display(null, denied); return }
            val request = requests[index]
            if (request.requiresAppPreview) { next(index + 1, denied); return }
            request.imageAsync { bytes, error ->
                if (bytes == null) { next(index + 1, denied || error is NativeMediaRequest.Rejected); return@imageAsync }
                val queued = System.nanoTime()
                NativeThumbBitmaps.decoders.execute {
                    val start = System.nanoTime()
                    val bitmap = runCatching { decodeSampled(bytes, pixels, request.cacheLabel) }.getOrNull()
                    val end = System.nanoTime()
                    NativeLog.i("ThumbLoad", "event=decode queue=read worker=bitmap waitMs=${(start - queued) / 1_000_000} ioMs=${(end - start) / 1_000_000} ms=${(end - queued) / 1_000_000} key=${request.cacheLabel}")
                    if (bitmap != null) {
                        NativeThumbBitmaps.put(first?.bitmapKey(pixels), bitmap, request.memoryExpiry())
                        display(bitmap, false)
                    } else if (retry && request.cacheKey != null) {
                        SharedPreviewBridge.queues.write(request.cacheLabel, { SharedPreviewBridge.invalidate(request.cacheKey) }) {
                            next(index, denied, false)
                        }
                    } else next(index + 1, denied)
                }
            }
        }
        next(0, false)
    }

    private fun decodeFirstImage(requests: List<NativeMediaRequest>, target: Int): Pair<Bitmap?, Boolean> {
        var denied = false
        for (request in requests) {
            if (request.requiresAppPreview) continue
            try {
                val bitmap = decodeSampled(request.readImage(), target, request.cacheLabel)
                if (bitmap != null) return bitmap to false
                NativeLog.i("PreviewImage", "event=error host=${request.diagnosticHost} errorCode=decode")
            } catch (error: NativeMediaRequest.Rejected) {
                denied = true
                NativeLog.i("PreviewImage", "event=error host=${request.diagnosticHost} errorCode=${error.code}")
            } catch (error: Exception) {
                val code = error.javaClass.simpleName.takeIf {
                    it.matches(Regex("[A-Za-z0-9_]{1,80}"))
                } ?: "request"
                NativeLog.i("PreviewImage", "event=error host=${request.diagnosticHost} errorCode=$code")
            }
        }
        return null to denied
    }

    private fun decodeSampled(bytes: ByteArray, target: Int, label: String): Bitmap? {
        return OrientedBitmap.decode(bytes, target, label)
    }

    private fun finish(result: List<Int>?) {
        if (finished) return
        finished = true
        hidePreview()
        main.post { onResult(result) }
    }

    fun release() {
        aiDialog?.dismiss()
        aiDialog = null
        hidePreview()
        shimmerAnim?.cancel()
        shimmerAnim = null
        pool.shutdownNow()
    }
}

/**
 * Uniform scale needed to fit a video inside a view without distortion.
 *
 * Pure math, kept next to its only caller and unit-tested on the JVM: applying
 * these factors about the view centre letterboxes the clip instead of pulling
 * it out of shape.
 */
internal data class VideoFit(val scaleX: Float, val scaleY: Float)

internal fun previewUsesVideo(video: Boolean, live: Boolean) = video || live

internal fun previewFirstFrame(info: Int) = info == 3

internal fun videoFitScale(
    videoWidth: Int,
    videoHeight: Int,
    viewWidth: Int,
    viewHeight: Int,
): VideoFit? {
    if (videoWidth <= 0 || videoHeight <= 0 || viewWidth <= 0 || viewHeight <= 0) return null
    val scale = minOf(
        viewWidth.toFloat() / videoWidth,
        viewHeight.toFloat() / videoHeight,
    )
    return VideoFit(
        scaleX = scale * videoWidth / viewWidth,
        scaleY = scale * videoHeight / viewHeight,
    )
}
