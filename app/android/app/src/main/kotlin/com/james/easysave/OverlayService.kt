package com.james.easysave

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
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
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * v1.6 validation: a draggable overlay bubble (snap to nearest edge) that
 *   - on tap: reads the clipboard through [ClipboardReaderActivity], and
 *   - on tap: shows a native Kotlin selection panel (Val 3 native option).
 */
class OverlayService : Service() {
    companion object {
        const val TAG = "V16VAL"
        const val CHANNEL_ID = "v16test"
        const val NOTIF_ID = 9002
    }

    private lateinit var wm: WindowManager
    private var bubble: View? = null
    private var panel: View? = null
    private lateinit var lp: WindowManager.LayoutParams

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        if (bubble == null) addBubble()
        return START_NOT_STICKY
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).roundToInt()

    private fun startForegroundCompat() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "v1.6 验证", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val notif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("v1.6 悬浮球验证")
            .setContentText("点击读剪贴板 + 原生选择面板")
            .setSmallIcon(android.R.drawable.ic_menu_search)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this, NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

    private fun addBubble() {
        val size = dp(56)
        val iv = TextView(this).apply {
            text = "↓"
            setTextColor(Color.WHITE)
            textSize = 22f
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                orientation = GradientDrawable.Orientation.LEFT_RIGHT
                colors = intArrayOf(Color.parseColor("#FC494C"), Color.parseColor("#FA662E"))
            }
            alpha = 0.85f
            elevation = dp(6).toFloat()
        }
        lp = WindowManager.LayoutParams(
            size, size, overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(8)
            y = dp(300)
        }
        attachDrag(iv)
        iv.setOnClickListener {
            Toast.makeText(this, "读取剪贴板…", Toast.LENGTH_SHORT).show()
            startActivity(
                Intent(this, ClipboardReaderActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            togglePanel()
        }
        wm.addView(iv, lp)
        bubble = iv
    }

    private fun attachDrag(v: View) {
        var downX = 0
        var downY = 0
        var startX = 0
        var startY = 0
        var moved = false
        v.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX.toInt(); downY = e.rawY.toInt()
                    startX = lp.x; startY = lp.y; moved = false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX.toInt() - downX
                    val dy = e.rawY.toInt() - downY
                    if (abs(dx) > dp(6) || abs(dy) > dp(6)) moved = true
                    lp.x = startX + dx
                    lp.y = startY + dy
                    wm.updateViewLayout(v, lp)
                }
                MotionEvent.ACTION_UP -> {
                    val screenW = resources.displayMetrics.widthPixels
                    lp.x = if (lp.x + dp(28) < screenW / 2) dp(8) else screenW - dp(64)
                    wm.updateViewLayout(v, lp)
                }
            }
            // Not consumed: the plain View's own click detection (with slop)
            // still fires the click when the user tapped without dragging.
            false
        }
    }

    private fun togglePanel() {
        panel?.let {
            wm.removeView(it)
            panel = null
            return
        }

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
            background = GradientDrawable().apply {
                setColor(0xFF26201C.toInt())
                cornerRadius = dp(20).toFloat()
            }
        }
        card.addView(TextView(this).apply {
            text = "选择下载（原生 Kotlin 面板验证）"
            setTextColor(Color.WHITE)
            textSize = 15f
        })

        val grid = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(12), 0, dp(12))
        }
        for (i in 0 until 3) {
            grid.addView(TextView(this).apply {
                text = "${i + 1}"
                gravity = Gravity.CENTER
                setTextColor(Color.WHITE)
                background = GradientDrawable().apply {
                    setColor(0xFF4A2622.toInt())
                    cornerRadius = dp(10).toFloat()
                }
                layoutParams = LinearLayout.LayoutParams(dp(64), dp(64)).apply { marginEnd = dp(8) }
            })
        }
        card.addView(grid)

        card.addView(TextView(this).apply {
            text = "下载选中"
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = GradientDrawable().apply {
                setColor(0xFFEA3B48.toInt())
                cornerRadius = dp(24).toFloat()
            }
            setOnClickListener {
                Toast.makeText(this@OverlayService, "原生面板按钮可用", Toast.LENGTH_SHORT).show()
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        })

        val plp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply { gravity = Gravity.CENTER }
        wm.addView(card, plp)
        panel = card
        Log.i(TAG, "Native selection panel shown")
    }

    override fun onDestroy() {
        try {
            panel?.let { wm.removeView(it) }
            bubble?.let { wm.removeView(it) }
        } catch (_: Exception) {
        }
        panel = null
        bubble = null
        super.onDestroy()
    }
}
