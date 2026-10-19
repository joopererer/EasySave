package com.james.easysave

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
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
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

enum class BubbleState { IDLE, MENU, BUSY, DONE, ERROR }

private data class BubbleError(val url: String?, val code: String?, val message: String?)

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

        /// Broadcast when the bubble is closed/shown; MainActivity forwards it
        /// to Dart so the settings toggle stays correct while the app is open.
        const val ACTION_BUBBLE_STATE = "com.james.easysave.action.BUBBLE_STATE"

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
        fun updateState(
            active: Boolean,
            done: Int,
            total: Int,
            label: String?,
            error: Boolean,
            url: String? = null,
            code: String? = null,
            message: String? = null,
        ) {
            instance?.applyState(
                active, done, total, label, error,
                if (url != null || code != null) BubbleError(url, code, message) else null,
            )
        }
    }

    private var wm: WindowManager? = null
    private var bubble: BubbleView? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var menu: View? = null
    private var pendingText: String? = null
    private var lastError: BubbleError? = null
    private var doneResetRunnable: Runnable? = null

    // Drag-to-close target.
    private var closeView: View? = null
    private var closeParams: WindowManager.LayoutParams? = null
    private var overClose = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        instance = this
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        startForegroundCompat()
        addBubble()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // If the process was restarted (START_STICKY), rebuild the bubble.
        if (bubble == null) {
            try {
                startForegroundCompat()
                addBubble()
            } catch (e: Exception) {
                Log.e(TAG, "restart addBubble failed: $e")
            }
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Best effort: re-arm shortly after the app is swiped away. (On MIUI
        // this may still require the user to allow background autostart.)
        try {
            val restart = Intent(applicationContext, OverlayService::class.java)
            val pi = PendingIntent.getService(
                applicationContext,
                7,
                restart,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val am = getSystemService(ALARM_SERVICE) as AlarmManager
            am.set(AlarmManager.RTC, System.currentTimeMillis() + 1000, pi)
        } catch (e: Exception) {
            Log.e(TAG, "onTaskRemoved restart failed: $e")
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isRunning = false
        instance = null
        doneResetRunnable?.let { bubble?.removeCallbacks(it) }
        removeMenu()
        removeClose()
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

    private fun baseFlags(): Int =
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS

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

    // ---------------------------------------------------------------- bubble

    private fun addBubble() {
        val params = WindowManager.LayoutParams(
            dp(SIZE_DP), dp(SIZE_DP), overlayType(), baseFlags(), PixelFormat.TRANSLUCENT
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
                        if (closeView == null) showClose()
                        params.x = startX + dx
                        params.y = startY + dy
                        clamp(params)
                        try {
                            wm?.updateViewLayout(view, params)
                        } catch (_: Exception) {
                        }
                        overClose = inCloseZone(
                            params.x + dp(SIZE_DP) / 2, params.y + dp(SIZE_DP) / 2
                        )
                        closeView?.alpha = if (overClose) 1f else 0.6f
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragging) {
                        if (overClose) closeBubble() else snap(params, view)
                        removeClose()
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
        // Error state: tap opens the same error page as a manual parse.
        if (bubble?.state == BubbleState.ERROR) {
            lastError?.let { openErrorPage(it); return }
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

    // ---------------------------------------------------------------- menu

    private fun showMenu() {
        removeMenu()
        val root = FrameLayout(this)
        root.setBackgroundColor(0x66000000)
        root.setOnClickListener { removeMenu() }

        val bp = bubbleParams
        val screenW = resources.displayMetrics.widthPixels
        val screenH = resources.displayMetrics.heightPixels
        val bcx = (bp?.x ?: 0).toFloat() + dp(SIZE_DP) / 2f
        val bcy = (bp?.y ?: 0).toFloat() + dp(SIZE_DP) / 2f
        val onRight = bcx > screenW / 2f
        val baseDeg = if (onRight) 180.0 else 0.0
        val spread = 52.0
        val radius = dp(120).toFloat()

        val items = listOf(
            Triple("all", "全部下载", R.drawable.ic_bubble_all),
            Triple("select", "选择下载", R.drawable.ic_bubble_select),
            Triple("caption", "复制文案", R.drawable.ic_bubble_caption),
            Triple("open", "打开 EasySave", R.drawable.ic_bubble_open),
        )
        for (i in items.indices) {
            val t = (i - 1.5) / 1.5
            val deg = Math.toRadians(baseDeg + t * spread)
            val cx = bcx + radius * cos(deg).toFloat()
            val cy = bcy + radius * sin(deg).toFloat()
            val item = makeItem(items[i].second, items[i].third) { onMenuAction(items[i].first) }
            val lp = FrameLayout.LayoutParams(dp(72), dp(78)).apply {
                leftMargin = (cx - dp(36)).roundToInt().coerceIn(0, screenW - dp(72))
                topMargin = (cy - dp(39)).roundToInt().coerceIn(dp(24), screenH - dp(78))
            }
            root.addView(item, lp)
        }

        menu = root
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType(), baseFlags(), PixelFormat.TRANSLUCENT
        )
        try {
            wm?.addView(root, params)
        } catch (e: Exception) {
            Log.e(TAG, "menu addView failed: $e")
        }
    }

    private fun makeItem(label: String, iconRes: Int, onTap: () -> Unit): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setOnClickListener { onTap() }
        }
        val circle = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xF2262524.toInt())
                setStroke(dp(1), 0x40FFFFFF)
            }
        }
        val icon = ImageView(this).apply {
            setImageResource(iconRes)
            layoutParams = FrameLayout.LayoutParams(dp(24), dp(24), Gravity.CENTER)
        }
        circle.addView(icon)
        column.addView(circle, LinearLayout.LayoutParams(dp(48), dp(48)))
        val tv = TextView(this).apply {
            text = label
            setTextColor(Color.WHITE)
            textSize = 11f
            gravity = Gravity.CENTER
            setPadding(0, dp(4), 0, 0)
        }
        column.addView(tv)
        return column
    }

    private fun removeMenu() {
        menu?.let { try { wm?.removeView(it) } catch (_: Exception) {} }
        menu = null
        if (bubble?.state == BubbleState.MENU) bubble?.state = BubbleState.IDLE
    }

    private fun onMenuAction(key: String) {
        val text = pendingText
        removeMenu()
        if (text.isNullOrBlank()) return
        when (key) {
            "all" -> HostService.submitText(this, text, "all", "bubble")
            "select" -> HostService.submitText(this, text, "select", "bubble")
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

    private fun openErrorPage(err: BubbleError) {
        try {
            val i = Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP
                )
                putExtra(HostService.EXTRA_ERROR_URL, err.url)
                putExtra(HostService.EXTRA_ERROR_CODE, err.code)
                putExtra(HostService.EXTRA_ERROR_MESSAGE, err.message)
            }
            startActivity(i)
        } catch (e: Exception) {
            Log.e(TAG, "openErrorPage failed: $e")
        }
    }

    // ---------------------------------------------------------------- close

    private fun closeCenterX(): Int = resources.displayMetrics.widthPixels / 2
    private fun closeCenterY(): Int = resources.displayMetrics.heightPixels - dp(120)

    private fun inCloseZone(x: Int, y: Int): Boolean {
        val dx = (x - closeCenterX()).toFloat()
        val dy = (y - closeCenterY()).toFloat()
        return dx * dx + dy * dy < (dp(72) * dp(72)).toFloat()
    }

    private fun showClose() {
        if (closeView != null) return
        val cv = CloseTargetView(this)
        val params = WindowManager.LayoutParams(
            dp(60), dp(60), overlayType(), baseFlags(), PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = closeCenterX() - dp(30)
            y = closeCenterY() - dp(30)
        }
        closeView = cv
        closeParams = params
        cv.alpha = 0.6f
        try {
            wm?.addView(cv, params)
        } catch (e: Exception) {
            Log.e(TAG, "close addView failed: $e")
        }
    }

    private fun removeClose() {
        closeView?.let { try { wm?.removeView(it) } catch (_: Exception) {} }
        closeView = null
        overClose = false
    }

    private fun closeBubble() {
        android.widget.Toast.makeText(
            this, "已关闭悬浮球，可在设置中重新开启", android.widget.Toast.LENGTH_SHORT
        ).show()
        // Mirror the Dart setting so 我的 → 设置 shows the toggle as off.
        try {
            getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                .edit()
                .putBoolean("flutter.bubbleEnabled", false)
                .apply()
        } catch (e: Exception) {
            Log.e(TAG, "persist bubbleEnabled failed: $e")
        }
        try {
            bubble?.let { wm?.removeView(it) }
        } catch (_: Exception) {
        }
        bubble = null
        try {
            sendBroadcast(Intent(ACTION_BUBBLE_STATE))
        } catch (e: Exception) {
            Log.e(TAG, "broadcast bubble state failed: $e")
        }
        stopSelf()
    }

    // ---------------------------------------------------------------- state

    private fun applyState(
        active: Boolean,
        done: Int,
        total: Int,
        label: String?,
        error: Boolean,
        err: BubbleError?,
    ) {
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
                lastError = err
                v.state = BubbleState.ERROR
                resetLater()
            }
            else -> {
                lastError = null
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
                val s = if (total > 0) "$done/$total" else "…"
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

/** The red ✕ drop target shown while dragging the bubble. */
private class CloseTargetView(context: Context) : View(context) {
    private val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xE6E53935.toInt() }
    private val fg = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = 3f * resources.displayMetrics.density
        strokeCap = Paint.Cap.ROUND
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        val r = min(w, h) / 2f
        val cx = w / 2f
        val cy = h / 2f
        canvas.drawCircle(cx, cy, r, bg)
        val d = r * 0.32f
        canvas.drawLine(cx - d, cy - d, cx + d, cy + d, fg)
        canvas.drawLine(cx + d, cy - d, cx - d, cy + d, fg)
    }
}
