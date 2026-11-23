package com.james.easysave.transfer

import android.util.Log
import com.james.easysave.NativeLog

/**
 * 传输日志统一入口。
 *
 * 格式要求：
 * - 统一前缀 [XFER]
 * - 记录 jobId 短码（首 8 字符）
 * - 记录状态转移 from→to
 * - 记录原因
 * - 记录重试序号
 * - 严禁记录 URL、cookie、token、文件路径
 */
object TransferLog {
    const val TAG = "XFER"

    var logListener: ((String) -> Unit)? = null

    fun shortId(jobId: String): String {
        return if (jobId.length <= 8) jobId else jobId.takeLast(8)
    }

    private fun formatLine(message: String): String {
        var cleaned = message.trim()
        while (cleaned.startsWith("[XFER]")) {
            cleaned = cleaned.removePrefix("[XFER]").trim()
        }
        return "[XFER] $cleaned"
    }

    fun logTransition(
        jobId: String,
        from: JobState,
        to: JobState,
        reason: String?,
        retryCount: Int = 0,
    ) {
        val line = formatLine("job=${shortId(jobId)} state=${from.value}->${to.value} reason=${reason ?: "none"} retry=$retryCount")
        runCatching { NativeLog.i(TAG, line) }
        logListener?.invoke(line)
    }

    fun logIllegalTransition(
        jobId: String,
        from: JobState,
        to: JobState,
        reason: String?,
    ) {
        val line = formatLine("job=${shortId(jobId)} illegal_transition ${from.value}->${to.value} rejected reason=${reason ?: "none"}")
        runCatching { NativeLog.w(TAG, line) }
        logListener?.invoke(line)
    }

    fun i(message: String) {
        val line = formatLine(message)
        runCatching { NativeLog.i(TAG, line) }
        logListener?.invoke(line)
    }

    fun w(message: String) {
        val line = formatLine(message)
        runCatching { NativeLog.w(TAG, line) }
        logListener?.invoke(line)
    }

    fun e(message: String, throwable: Throwable? = null) {
        val line = formatLine(message)
        runCatching { NativeLog.e(TAG, line, throwable) }
        logListener?.invoke(line)
    }
}

