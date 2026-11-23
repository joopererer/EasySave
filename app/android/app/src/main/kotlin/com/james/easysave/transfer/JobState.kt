package com.james.easysave.transfer

import android.util.Log

/**
 * 传输任务状态及显式状态转移表。
 *
 * 状态定义：
 * - queued: 排队中
 * - running: 执行中
 * - waiting_network: 等待网络恢复
 * - paused: 用户暂停
 * - interrupted: 异常中断（如重试耗尽、服务超时、被杀）
 * - storage_full: 存储空间不足
 * - finishing: 收尾校验/写入中
 * - done: 完成（终态）
 * - failed: 失败（终态）
 * - canceled: 已取消（终态）
 *
 * 显式转移规则：
 * 允许：
 * - queued → running
 * - running → paused / waiting_network / interrupted / storage_full / finishing / failed / canceled
 * - paused / waiting_network / interrupted / storage_full → queued
 * - finishing → done / failed
 * - 所有非终态 → canceled
 * 非法转移一律拒绝并记录日志，不向 UI 抛出异常。
 */
enum class JobState(val value: String) {
    QUEUED("queued"),
    RUNNING("running"),
    WAITING_NETWORK("waiting_network"),
    PAUSED("paused"),
    INTERRUPTED("interrupted"),
    STORAGE_FULL("storage_full"),
    FINISHING("finishing"),
    DONE("done"),
    FAILED("failed"),
    CANCELED("canceled");

    val isTerminal: Boolean
        get() = this == DONE || this == FAILED || this == CANCELED

    companion object {
        fun fromValue(value: String): JobState {
            return entries.firstOrNull { it.value.equals(value, ignoreCase = true) }
                ?: throw IllegalArgumentException("Unknown JobState: $value")
        }

        private val ALLOWED_TRANSITIONS: Map<JobState, Set<JobState>> = mapOf(
            QUEUED to setOf(RUNNING, CANCELED),
            RUNNING to setOf(PAUSED, WAITING_NETWORK, INTERRUPTED, STORAGE_FULL, FINISHING, FAILED, CANCELED),
            PAUSED to setOf(QUEUED, CANCELED),
            WAITING_NETWORK to setOf(QUEUED, CANCELED),
            INTERRUPTED to setOf(QUEUED, CANCELED),
            STORAGE_FULL to setOf(QUEUED, CANCELED),
            FINISHING to setOf(DONE, FAILED, CANCELED),
            DONE to emptySet(),
            FAILED to emptySet(),
            CANCELED to emptySet(),
        )

        /**
         * 检查状态转移是否合法。
         */
        fun canTransition(from: JobState, to: JobState): Boolean {
            return ALLOWED_TRANSITIONS[from]?.contains(to) == true
        }

        /**
         * 校验转移合法性并记录日志。非法转移返回 false。
         */
        fun validateAndLog(
            jobId: String,
            from: JobState,
            to: JobState,
            reason: String? = null,
            retryCount: Int = 0,
        ): Boolean {
            if (canTransition(from, to)) {
                TransferLog.logTransition(jobId, from, to, reason, retryCount)
                return true
            }
            TransferLog.logIllegalTransition(jobId, from, to, reason)
            return false
        }
    }
}

