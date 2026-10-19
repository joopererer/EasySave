package com.james.easysave

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

enum class BubbleState { IDLE, MENU, BUSY, DONE, ERROR }

/**
 * v1.6 floating bubble (optional, default off). Native Kotlin overlay that reads
 * the clipboard via [ClipboardReaderActivity] and hands work to [HostService].
 * The bubble itself never runs Dart; it only reflects state pushed by
 * [HostService.updateState].
 */
class OverlayService : Service() {
    companion object {
        const val TAG = "V16BUBBLE"
        private const val CHANNEL_ID = "easysave_bubble"
        private const val NOTIF_ID = 9012
        private const val SIZE_DP = 54

        @Volatile var isRunning = false
            private set

        private var instance: OverlayService? = null

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context, Intent(context, OverlayService::class.java)
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, OverlayService::class.java))
        }

        /** Push a state update from HostService. */
        fun updateState(active: Boolean, done: Int, total: Int, label: String?, error: Boolean) {
            instance?.applyState(active, done, total, label, error)
        }
    }

    private var wm: WindowManager? = null
    private var bubble: BubbleView? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var menu: View? = null
    private var pendingText: String? = null
    private var doneResetRunnable: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        instance = this
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        startForegroundCompat()
        addBubble()
    }

    override fun onDestroy() {
        isRunning = false
        instance = null
        doneResetRunnable?.let { bubble?.removeCallbacks(it) }
        removeMenu()
        bubble?.let { try { wm?.removeView(it) } catch (_: Exception) {} }
        bubble = null
        super.onDestroy()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).roundToInt()

    private fun overlayType(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
    } else {
        @Suppress("DEPRECATION")
        WindowManager.LayoutParams.TYPE_PHONE
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "EasySave 悬浮球", NotificationManager.IMPORTANCE_MIN)
            )
        }
        val notif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("EasySave 悬浮球")
            .setContentText("点击气泡可下载剪贴板中的链接")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .build()
        startForeground(NOTIF_ID, notif)
    }

    private fun addBubble() {
        val params = WindowManager.LayoutParams(
            dp(SIZE_DP), dp(SIZE_DP), overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = resources.displayMetrics.widthPixels - dp(SIZE_DP + 6)
            y = resources.displayMetrics.heightPixels / 3
        }
        val v = BubbleView(this)
        v.alpha = 0.82f
        attachTouch(v, params)
        bubble = v
        bubbleParams = params
        try {
            wm?.addView(v, params)
        } catch (e: Exception) {
            Log.e(TAG, "addView failed: $e")
        }
    }

    private fun attachTouch(v: View, params: WindowManager.LayoutParams) {
        var startX = 0
        var startY = 0
        var touchX = 0f
        var touchY = 0f
        var dragging = false
        v.setOnTouchListener { view, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x
                    startY = params.y
                    touchX = e.rawX
                    touchY = e.rawY
                    dragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - touchX).toInt()
                    val dy = (e.rawY - touchY).toInt()
                    if (abs(dx) > dp(6) || abs(dy) > dp(6)) dragging = true
                    if (dragging) {
                        removeMenu()
                        params.x = startX + dx
                        params.y = startY + dy
                        clamp(params)
                        try {
                            wm?.updateViewLayout(view, params)
                        } catch (_: Exception) {
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragging) {
                        snap(params, view)
                    } else {
                        onClickBubble()
                    }
                    true
                }
                else -> false
            }
        }
    }

    private fun clamp(params: WindowManager.LayoutParams) {
        val screenW = resources.displayMetrics.widthPixels
        val screenH = resources.displayMetrics.heightPixels
        params.x = params.x.coerceIn(-dp(8), screenW - dp(SIZE_DP) + dp(8))
        params.y = params.y.coerceIn(dp(24), screenH - dp(SIZE_DP + 24))
    }

    private fun snap(params: WindowManager.LayoutParams, view: View) {
        val screenW = resources.displayMetrics.widthPixels
        params.x = if (params.x + dp(SIZE_DP) / 2 < screenW / 2) -dp(6) else screenW - dp(SIZE_DP - 6)
        try {
            wm?.updateViewLayout(view, params)
        } catch (_: Exception) {
        }
    }

    private fun onClickBubble() {
        if (menu != null) {
            removeMenu()
            return
        }
        ClipboardReaderActivity.listener = { text ->
            val t = text?.trim().orEmpty()
            if (t.contains("http", ignoreCase = true)) {
                pendingText = t
                showMenu()
            }
            // No link: ClipboardReaderActivity already toasted the hint.
        }
        val intent = Intent(this, ClipboardReaderActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(ClipboardReaderActivity.EXTRA_EMPTY_MESSAGE, "先在 App 里复制链接")
        }
        try {
            startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "startActivity clipboard failed: $e")
        }
    }

    private fun showMenu() {
        removeMenu()
        val m = buildMenu()
        val params = WindowManager.LayoutParams(
            dp(150), WindowManager.LayoutParams.WRAP_CONTENT, overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply { gravity = Gravity.TOP or Gravity.START }
        val bp = bubbleParams
        val screenW = resources.displayMetrics.widthPixels
        val onRight = (bp?.x ?: 0) + dp(SIZE_DP) / 2 > screenW / 2
        val bx = bp?.x ?: 0
        val by = bp?.y ?: 0
        params.x = if (onRight) (bx - dp(150 + 6)).coerceAtLeast(0) else (bx + dp(SIZE_DP + 6))
        params.y = by.coerceAtLeast(dp(24))
        menu = m
        try {
            wm?.addView(m, params)
        } catch (e: Exception) {
            Log.e(TAG, "menu addView failed: $e")
        }
    }

    private fun buildMenu(): View {
        val items = listOf(
            "all" to "全部下载",
            "select" to "选择下载",
            "caption" to "复制文案",
            "open" to "打开 EasySave",
        )
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(0xF2201F1E.toInt())
                setStroke(dp(1), 0x33FFFFFF)
            }
            setPadding(dp(6), dp(6), dp(6), dp(6))
        }
        for ((key, label) in items) {
            val row = TextView(this).apply {
                text = label
                setTextColor(Color.WHITE)
                textSize = 14f
                setPadding(dp(14), dp(11), dp(14), dp(11))
                setOnClickListener {
                    onMenuAction(key)
                }
            }
            container.addView(row)
        }
        return container
    }

    private fun removeMenu() {
        menu?.let { try { wm?.removeView(it) } catch (_: Exception) {} }
        menu = null
        bubble?.state = if (bubble?.state == BubbleState.MENU) BubbleState.IDLE else bubble?.state ?: BubbleState.IDLE
    }

    private fun onMenuAction(key: String) {
        val text = pendingText
        removeMenu()
        if (text.isNullOrBlank()) return
        when (key) {
            "all" -> HostService.submitText(this, text, "all", "bubble")
            "select" -> android.widget.Toast.makeText(
                this, "选择下载即将上线", android.widget.Toast.LENGTH_SHORT
            ).show()
            "caption" -> HostService.submitText(this, text, "caption", "bubble")
            "open" -> openAppToPreview(text)
        }
    }

    private fun openAppToPreview(text: String) {
        try {
            val i = Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP
                )
                putExtra(MainActivity.EXTRA_OPEN_URL, text)
            }
            startActivity(i)
        } catch (e: Exception) {
            Log.e(TAG, "openApp failed: $e")
        }
    }

    private fun applyState(active: Boolean, done: Int, total: Int, label: String?, error: Boolean) {
        val v = bubble ?: return
        doneResetRunnable?.let { v.removeCallbacks(it) }
        when {
            active -> {
                v.state = BubbleState.BUSY
                v.done = done
                v.total = total
                v.label = label
            }
            error -> {
                v.state = BubbleState.ERROR
                resetLater()
            }
            else -> {
                v.state = BubbleState.DONE
                resetLater()
            }
        }
        v.invalidate()
    }

    private fun resetLater() {
        val v = bubble ?: return
        val r = Runnable {
            if (v.state == BubbleState.DONE || v.state == BubbleState.ERROR) {
                v.state = BubbleState.IDLE
                v.invalidate()
            }
        }
        doneResetRunnable = r
        v.postDelayed(r, 2500)
    }
}

/** The circular bubble: gradient fill + state indicator (progress / ✓ / !). */
private class BubbleView(context: Context) : View(context) {
    var state: BubbleState = BubbleState.IDLE
    var done = 0
    var total = 0
    var label: String? = null

    private val bg = Paint(Paint.ANTI_ALIAS_FLAG)
    private val fg = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = 3f * resources.displayMetrics.density
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textAlign = Paint.Align.CENTER
        textSize = 12f * resources.displayMetrics.density
        typeface = Typeface.DEFAULT_BOLD
    }
    private val arc = RectF()

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        val r = min(w, h) / 2f - fg.strokeWidth
        val cx = w / 2f
        val cy = h / 2f
        bg.shader = LinearGradient(
            0f, 0f, w, h,
            intArrayOf(0xFFFC494C.toInt(), 0xFFFA662E.toInt()),
            null, Shader.TileMode.CLAMP
        )
        canvas.drawCircle(cx, cy, r, bg)

        when (state) {
            BubbleState.BUSY -> {
                val frac = if (total > 0) done.toFloat() / total else 0f
                arc.set(cx - r + 3, cy - r + 3, cx + r - 3, cy + r - 3)
                canvas.drawArc(arc, -90f, 360f * frac.coerceIn(0f, 1f), false, fg)
                val s = if (total > 0) "$done/$total" else (label ?: "…")
                canvas.drawText(s, cx, cy + text.textSize / 3f, text)
            }
            BubbleState.DONE -> {
                val p = Path().apply {
                    moveTo(cx - r * 0.42f, cy)
                    lineTo(cx - r * 0.08f, cy + r * 0.34f)
                    lineTo(cx + r * 0.46f, cy - r * 0.34f)
                }
                canvas.drawPath(p, fg)
            }
            BubbleState.ERROR -> {
                canvas.drawLine(cx, cy - r * 0.42f, cx, cy + r * 0.12f, fg)
                canvas.drawPoint(cx, cy + r * 0.42f, fg)
            }
            else -> {
                // Download arrow (line icon).
                canvas.drawLine(cx, cy - r * 0.44f, cx, cy + r * 0.16f, fg)
                val p = Path().apply {
                    moveTo(cx - r * 0.26f, cy - r * 0.06f)
                    lineTo(cx, cy + r * 0.2f)
                    lineTo(cx + r * 0.26f, cy - r * 0.06f)
                }
                canvas.drawPath(p, fg)
                canvas.drawLine(cx - r * 0.34f, cy + r * 0.42f, cx + r * 0.34f, cy + r * 0.42f, fg)
            }
        }
    }
}
