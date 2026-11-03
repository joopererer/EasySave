package com.james.easysave

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.WindowInsets
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.view.animation.AccelerateDecelerateInterpolator
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
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
        private const val HIDE_OFFSET_DP = 21

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

        fun updateAutoHide(enabled: Boolean) {
            instance?.setAutoHide(enabled)
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
    private var bubbleContainer: FrameLayout? = null
    private var bubble: BubbleView? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var menu: View? = null
    private var pendingText: String? = null
    private var lastError: BubbleError? = null
    private var doneResetRunnable: Runnable? = null
    private var idleHideRunnable: Runnable? = null
    private var isHalfHidden = false
    private var isSnappedToLeft = false
    private var autoHideEnabled = true
    private var lastBubbleBounds: BubbleBounds? = null
    private var bubbleTouched = false

    // Drag-to-close target.
    private var closeView: View? = null
    private var closeParams: WindowManager.LayoutParams? = null
    private var overClose = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        NativeLog.init(this)
        isRunning = true
        instance = this
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        autoHideEnabled = loadAutoHideSetting()
        startForegroundCompat()
        addBubble()
    }

    private fun loadAutoHideSetting(): Boolean {
        return try {
            getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                .getBoolean("flutter.bubbleAutoHide", true)
        } catch (_: Exception) {
            true
        }
    }

    fun setAutoHide(enabled: Boolean) {
        autoHideEnabled = enabled
        if (!enabled) {
            slideOut(immediate = false)
        } else {
            if (bubble?.state == BubbleState.IDLE && menu == null) {
                scheduleIdleHide(2500L)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // If the process was restarted (START_STICKY), rebuild the bubble.
        if (bubble == null) {
            try {
                startForegroundCompat()
                addBubble()
            } catch (e: Exception) {
                NativeLog.e(TAG, "restart addBubble failed: $e")
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
            NativeLog.e(TAG, "onTaskRemoved restart failed: $e")
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isRunning = false
        instance = null
        doneResetRunnable?.let { bubble?.removeCallbacks(it) }
        idleHideRunnable?.let { bubble?.removeCallbacks(it) }
        removeMenu()
        removeClose()
        bubbleContainer?.let { try { wm?.removeView(it) } catch (_: Exception) {} }
        bubbleContainer = null
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

    @Suppress("DEPRECATION")
    private fun bubbleBounds(): BubbleBounds {
        val manager = wm ?: return BubbleBounds(0, 0, 0, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val metrics = manager.currentWindowMetrics
            val insets = metrics.windowInsets.getInsets(
                WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
            )
            return BubbleBounds(insets.left, insets.top, metrics.bounds.width() - insets.right, metrics.bounds.height() - insets.bottom)
        }
        val metrics = DisplayMetrics()
        manager.defaultDisplay.getRealMetrics(metrics)
        val insets = bubbleContainer?.rootWindowInsets
        val cutout = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) insets?.displayCutout else null
        return BubbleBounds(
            maxOf(insets?.systemWindowInsetLeft ?: 0, cutout?.safeInsetLeft ?: 0),
            maxOf(insets?.systemWindowInsetTop ?: 0, cutout?.safeInsetTop ?: 0),
            metrics.widthPixels - maxOf(insets?.systemWindowInsetRight ?: 0, cutout?.safeInsetRight ?: 0),
            metrics.heightPixels - maxOf(insets?.systemWindowInsetBottom ?: 0, cutout?.safeInsetBottom ?: 0),
        )
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val view = bubbleContainer ?: return
        val params = bubbleParams ?: return
        val previous = lastBubbleBounds ?: return
        pendingRotationFraction = previous.fraction(params.y, dp(SIZE_DP))
        removeMenu()
        removeClose()
        view.requestApplyInsets()
    }

    private var pendingRotationFraction: Float? = null

    private fun resnapAfterInsets(view: View, params: WindowManager.LayoutParams) {
        val previous = lastBubbleBounds ?: return
        val bounds = bubbleBounds()
        if (bubbleTouched) return
        val position = resnappedPosition(previous, bounds, params.y, dp(SIZE_DP), isSnappedToLeft, pendingRotationFraction) ?: return
        pendingRotationFraction = null
        params.x = position.first
        params.y = position.second
        lastBubbleBounds = bounds
        try {
            wm?.updateViewLayout(view, params)
        } catch (e: Exception) {
            NativeLog.e(TAG, "insets reposition failed", e)
        }
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
            .setSmallIcon(R.drawable.ic_stat_easysave)
            .setOngoing(true)
            .build()
        startForeground(NOTIF_ID, notif)
    }

    // ---------------------------------------------------------------- bubble

    private fun scheduleIdleHide(delayMs: Long = 2500L) {
        val b = bubble ?: return
        idleHideRunnable?.let { b.removeCallbacks(it) }
        if (!autoHideEnabled) return
        if (b.state != BubbleState.IDLE || menu != null) return
        val r = Runnable {
            slideIn()
        }
        idleHideRunnable = r
        b.postDelayed(r, delayMs)
    }

    private fun slideIn() {
        val b = bubble ?: return
        if (!autoHideEnabled) return
        if (b.state != BubbleState.IDLE || menu != null) return
        if (isHalfHidden) return
        isHalfHidden = true
        val targetTx = if (isSnappedToLeft) -dp(HIDE_OFFSET_DP).toFloat() else dp(HIDE_OFFSET_DP).toFloat()
        b.animate()
            .translationX(targetTx)
            .alpha(0.6f)
            .setDuration(200)
            .setInterpolator(AccelerateDecelerateInterpolator())
            .start()
    }

    private fun slideOut(immediate: Boolean = false) {
        val b = bubble ?: return
        idleHideRunnable?.let { b.removeCallbacks(it) }
        isHalfHidden = false
        if (immediate) {
            b.animate().cancel()
            b.translationX = 0f
            b.alpha = 0.8f
        } else {
            b.animate()
                .translationX(0f)
                .alpha(0.8f)
                .setDuration(200)
                .setInterpolator(AccelerateDecelerateInterpolator())
                .start()
        }
    }

    private fun addBubble() {
        val bounds = bubbleBounds()
        lastBubbleBounds = bounds

        val params = WindowManager.LayoutParams(
            dp(SIZE_DP), dp(SIZE_DP), overlayType(), baseFlags(), PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            flags = flags or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) fitInsetsTypes = 0
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
            x = bounds.snapX(false, dp(SIZE_DP))
            y = bounds.yAt(0.33f, dp(SIZE_DP))
        }
        val container = FrameLayout(this).apply {
            clipChildren = false
            clipToPadding = false
        }
        container.setOnApplyWindowInsetsListener { view, insets ->
            view.postOnAnimation {
                if (bubbleContainer === view) resnapAfterInsets(view, params)
            }
            insets
        }
        val v = BubbleView(this)
        v.alpha = 0.8f
        container.addView(v, FrameLayout.LayoutParams(dp(SIZE_DP), dp(SIZE_DP)))
        attachTouch(container, params)
        bubbleContainer = container
        bubble = v
        bubbleParams = params
        isSnappedToLeft = false
        try {
            wm?.addView(container, params)
        } catch (e: Exception) {
            NativeLog.e(TAG, "addView failed: $e")
        }
        scheduleIdleHide(2500L)
    }

    private fun attachTouch(container: View, params: WindowManager.LayoutParams) {
        var startX = 0
        var startY = 0
        var touchX = 0f
        var touchY = 0f
        var dragging = false
        container.setOnTouchListener { view, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    bubbleTouched = true
                    startX = params.x
                    startY = params.y
                    touchX = e.rawX
                    touchY = e.rawY
                    dragging = false
                    idleHideRunnable?.let { bubble?.removeCallbacks(it) }
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - touchX).toInt()
                    val dy = (e.rawY - touchY).toInt()
                    val dist = hypot(dx.toDouble(), dy.toDouble())
                    if (!dragging && dist >= dp(10)) {
                        dragging = true
                        if (isHalfHidden) {
                            slideOut(immediate = true)
                        }
                    }
                    if (dragging) {
                        removeMenu()
                        if (closeView == null) showClose()
                        params.x = startX + dx
                        params.y = startY + dy
                        clampDrag(params)
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
                    bubbleTouched = false
                    if (dragging) {
                        if (overClose) closeBubble() else snap(params, view)
                        removeClose()
                    } else {
                        resnapAfterInsets(view, params)
                        onClickBubble()
                    }
                    true
                }
                else -> false
            }
        }
    }

    private fun clampDrag(params: WindowManager.LayoutParams) {
        val bounds = bubbleBounds()
        lastBubbleBounds = bounds
        params.x = params.x.coerceIn(bounds.left, bounds.maxX(dp(SIZE_DP)))
        params.y = params.y.coerceIn(bounds.top, bounds.maxY(dp(SIZE_DP)))
    }

    private fun snap(params: WindowManager.LayoutParams, view: View) {
        val bounds = bubbleBounds()
        pendingRotationFraction = null
        lastBubbleBounds = bounds
        isSnappedToLeft = (params.x + dp(SIZE_DP) / 2 < (bounds.left + bounds.right) / 2)
        params.x = bounds.snapX(isSnappedToLeft, dp(SIZE_DP))
        params.y = params.y.coerceIn(bounds.top, bounds.maxY(dp(SIZE_DP)))
        try {
            wm?.updateViewLayout(view, params)
        } catch (_: Exception) {
        }
        if (bubble?.state == BubbleState.IDLE && menu == null) {
            scheduleIdleHide(2500L)
        }
    }

    private fun onClickBubble() {
        if (menu != null) {
            removeMenu()
            return
        }
        if (isHalfHidden) {
            slideOut(immediate = false)
        }
        // Busy state: tap toasts current progress, does not re-trigger.
        if (bubble?.state == BubbleState.BUSY) {
            val total = bubble?.total ?: 0
            val done = bubble?.done ?: 0
            val msg = if (total > 0) "正在下载 ($done/$total)" else "正在下载中…"
            android.widget.Toast.makeText(this, msg, android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        // Error state: tap opens the same error page as a manual parse.
        if (bubble?.state == BubbleState.ERROR) {
            lastError?.let { openErrorPage(it); return }
        }
        ClipboardReaderActivity.listener = { text ->
            val t = text?.trim().orEmpty()
            if (ExternalHandlers.handle(this, t)) {
                scheduleIdleHide(2500L)
            } else if (SupportedLinks.containsSupportedUrl(t, this)) {
                pendingText = t
                showMenu()
            } else {
                scheduleIdleHide(2500L)
            }
        }
        val intent = Intent(this, ClipboardReaderActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(ClipboardReaderActivity.EXTRA_EMPTY_MESSAGE, "先在 App 里复制链接")
        }
        try {
            startActivity(intent)
        } catch (e: Exception) {
            NativeLog.e(TAG, "startActivity clipboard failed: $e")
            scheduleIdleHide(2500L)
        }
    }

    // ---------------------------------------------------------------- menu

    private fun showMenu() {
        removeMenu()
        slideOut(immediate = true)
        bubble?.state = BubbleState.MENU
        val root = FrameLayout(this)
        root.setBackgroundColor(0x66000000)
        root.setOnClickListener { removeMenu() }

        val bp = bubbleParams
        val bounds = bubbleBounds()
        val bcx = (bp?.x ?: 0).toFloat() + dp(SIZE_DP) / 2f
        val bcy = (bp?.y ?: 0).toFloat() + dp(SIZE_DP) / 2f
        val onRight = bcx > (bounds.left + bounds.right) / 2f
        val baseDeg = if (onRight) 180.0 else 0.0
        val spread = 52.0
        val radius = dp(120).toFloat()

        val items = listOf(
            Triple("all", "全部下载", R.drawable.ic_menu_download_all),
            Triple("select", "选择下载", R.drawable.ic_menu_select),
            Triple("caption", "复制文案", R.drawable.ic_menu_caption),
            Triple("open", "打开 EasySave", R.drawable.ic_menu_open),
        )
        for (i in items.indices) {
            val t = (i - 1.5) / 1.5
            val deg = Math.toRadians(baseDeg + t * spread)
            val cx = bcx + radius * cos(deg).toFloat()
            val cy = bcy + radius * sin(deg).toFloat()
            val item = makeItem(items[i].second, items[i].third) { onMenuAction(items[i].first) }
            val lp = FrameLayout.LayoutParams(dp(72), dp(78)).apply {
                leftMargin = (cx - dp(36)).roundToInt().coerceIn(bounds.left, (bounds.right - dp(72)).coerceAtLeast(bounds.left))
                topMargin = (cy - dp(39)).roundToInt().coerceIn(bounds.top, (bounds.bottom - dp(78)).coerceAtLeast(bounds.top))
            }
            root.addView(item, lp)
        }

        menu = root
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType(), baseFlags() or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN, PixelFormat.TRANSLUCENT
        ).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) fitInsetsTypes = 0
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        try {
            wm?.addView(root, params)
        } catch (e: Exception) {
            NativeLog.e(TAG, "menu addView failed: $e")
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
        if (bubble?.state == BubbleState.MENU) {
            bubble?.state = BubbleState.IDLE
            scheduleIdleHide(2500L)
        }
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
            NativeLog.e(TAG, "openApp failed: $e")
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
            NativeLog.e(TAG, "openErrorPage failed: $e")
        }
    }

    // ---------------------------------------------------------------- close

    private fun closeCenterX(): Int = bubbleBounds().let { (it.left + it.right) / 2 }
    private fun closeCenterY(): Int = bubbleBounds().bottom - dp(120)

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
            flags = flags or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) fitInsetsTypes = 0
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
            x = closeCenterX() - dp(30)
            y = closeCenterY() - dp(30)
        }
        closeView = cv
        closeParams = params
        cv.alpha = 0.6f
        try {
            wm?.addView(cv, params)
        } catch (e: Exception) {
            NativeLog.e(TAG, "close addView failed: $e")
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
        idleHideRunnable?.let { bubble?.removeCallbacks(it) }
        doneResetRunnable?.let { bubble?.removeCallbacks(it) }
        // Mirror the Dart setting so 我的 → 设置 shows the toggle as off.
        try {
            getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                .edit()
                .putBoolean("flutter.bubbleEnabled", false)
                .apply()
        } catch (e: Exception) {
            NativeLog.e(TAG, "persist bubbleEnabled failed: $e")
        }
        try {
            bubbleContainer?.let { wm?.removeView(it) }
        } catch (_: Exception) {
        }
        bubbleContainer = null
        bubble = null
        try {
            sendBroadcast(Intent(ACTION_BUBBLE_STATE))
        } catch (e: Exception) {
            NativeLog.e(TAG, "broadcast bubble state failed: $e")
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
        idleHideRunnable?.let { v.removeCallbacks(it) }
        slideOut(immediate = false)
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
                scheduleIdleHide(2500L)
            }
        }
        doneResetRunnable = r
        v.postDelayed(r, 2500)
    }
}

/** The circular bubble: bg_bubble drawable + overlay state indicator. */
private class BubbleView(context: Context) : FrameLayout(context) {
    var state: BubbleState = BubbleState.IDLE
        set(value) {
            field = value
            updateIndicator()
        }
    var done = 0
    var total = 0
    var label: String? = null

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
    private lateinit var indicatorView: View
    private lateinit var arrowView: ImageView

    init {
        background = ContextCompat.getDrawable(context, R.drawable.bg_bubble)

        // Draws the busy / done / error glyphs on top of bg_bubble.
        indicatorView = object : View(context) {
            override fun onDraw(canvas: Canvas) {
                val w = width.toFloat()
                val h = height.toFloat()
                val r = min(w, h) / 2f - fg.strokeWidth
                val cx = w / 2f
                val cy = h / 2f

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
                        // IDLE / MENU: the arrow is the ic_bubble_arrow ImageView below.
                    }
                }
            }
        }
        addView(indicatorView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))

        // ic_bubble_arrow centered at ~62% of the bubble diameter. The bubble
        // is SIZE_DP (54dp) wide, so 62% is 33dp.
        val arrowSize = (54 * 0.62f * resources.displayMetrics.density).roundToInt()
        arrowView = ImageView(context).apply {
            setImageResource(R.drawable.ic_bubble_arrow)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        addView(arrowView, LayoutParams(arrowSize, arrowSize, Gravity.CENTER))
    }

    private fun updateIndicator() {
        // The arrow shows when idle; busy / done / error draw their own glyph.
        arrowView.visibility =
            if (state == BubbleState.IDLE || state == BubbleState.MENU) VISIBLE else INVISIBLE
        indicatorView.invalidate()
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
