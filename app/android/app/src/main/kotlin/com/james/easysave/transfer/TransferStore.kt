package com.james.easysave.transfer

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * 传输任务持久化存储（transfer.db，基于 SQLiteOpenHelper，不用 Room）。
 *
 * 任务表结构：
 * - job_id: 主键
 * - direction: download / upload
 * - state: 状态字符串
 * - retry_count: 重试次数
 * - batch_id: 批次 id
 * - category: 分类（image / large_file）
 * - created_at: 创建时间戳
 * - updated_at: 更新时间戳
 * - fake_plan: 用于自检/测试的计划标记
 *
 * 严格不存储 cookie、token 及完整 URL 的 query。
 */
class TransferStore(context: Context, dbName: String = DB_NAME) :
    SQLiteOpenHelper(context, dbName, null, DB_VERSION) {

    companion object {
        const val DB_NAME = "transfer.db"
        const val DB_VERSION = 1
        const val TABLE_JOBS = "transfer_jobs"

        const val COL_JOB_ID = "job_id"
        const val COL_DIRECTION = "direction"
        const val COL_STATE = "state"
        const val COL_RETRY_COUNT = "retry_count"
        const val COL_BATCH_ID = "batch_id"
        const val COL_CATEGORY = "category"
        const val COL_CREATED_AT = "created_at"
        const val COL_UPDATED_AT = "updated_at"
        const val COL_FAKE_PLAN = "fake_plan"
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS $TABLE_JOBS (
                $COL_JOB_ID TEXT PRIMARY KEY,
                $COL_DIRECTION TEXT NOT NULL,
                $COL_STATE TEXT NOT NULL,
                $COL_RETRY_COUNT INTEGER NOT NULL DEFAULT 0,
                $COL_BATCH_ID TEXT,
                $COL_CATEGORY TEXT NOT NULL,
                $COL_CREATED_AT INTEGER NOT NULL,
                $COL_UPDATED_AT INTEGER NOT NULL,
                $COL_FAKE_PLAN TEXT
            )
            """.trimIndent()
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // v1 为初始版本
    }

    @Synchronized
    fun insertOrReplace(job: TransferJob) {
        val values = ContentValues().apply {
            put(COL_JOB_ID, job.jobId)
            put(COL_DIRECTION, job.direction.value)
            put(COL_STATE, job.state.value)
            put(COL_RETRY_COUNT, job.retryCount)
            put(COL_BATCH_ID, job.batchId)
            put(COL_CATEGORY, job.category.value)
            put(COL_CREATED_AT, job.createdAt)
            put(COL_UPDATED_AT, job.updatedAt)
            put(COL_FAKE_PLAN, job.fakePlan)
        }
        writableDatabase.insertWithOnConflict(
            TABLE_JOBS,
            null,
            values,
            SQLiteDatabase.CONFLICT_REPLACE
        )
    }

    @Synchronized
    fun updateJobState(
        jobId: String,
        state: JobState,
        retryCount: Int? = null,
        updatedAt: Long = System.currentTimeMillis(),
    ) {
        val values = ContentValues().apply {
            put(COL_STATE, state.value)
            put(COL_UPDATED_AT, updatedAt)
            if (retryCount != null) {
                put(COL_RETRY_COUNT, retryCount)
            }
        }
        writableDatabase.update(
            TABLE_JOBS,
            values,
            "$COL_JOB_ID = ?",
            arrayOf(jobId)
        )
    }

    @Synchronized
    fun getJob(jobId: String): TransferJob? {
        readableDatabase.query(
            TABLE_JOBS,
            null,
            "$COL_JOB_ID = ?",
            arrayOf(jobId),
            null,
            null,
            null
        ).use { cursor ->
            if (cursor.moveToFirst()) {
                return cursorToJob(cursor)
            }
        }
        return null
    }

    @Synchronized
    fun getAllJobs(): List<TransferJob> {
        val list = mutableListOf<TransferJob>()
        readableDatabase.query(
            TABLE_JOBS,
            null,
            null,
            null,
            null,
            null,
            "$COL_CREATED_AT ASC"
        ).use { cursor ->
            while (cursor.moveToNext()) {
                list.add(cursorToJob(cursor))
            }
        }
        return list
    }

    @Synchronized
    fun getActiveJobs(): List<TransferJob> {
        val list = mutableListOf<TransferJob>()
        val terminalStates = arrayOf(
            JobState.DONE.value,
            JobState.FAILED.value,
            JobState.CANCELED.value
        )
        val placeholders = terminalStates.joinToString(",") { "?" }
        readableDatabase.query(
            TABLE_JOBS,
            null,
            "$COL_STATE NOT IN ($placeholders)",
            terminalStates,
            null,
            null,
            "$COL_CREATED_AT ASC"
        ).use { cursor ->
            while (cursor.moveToNext()) {
                list.add(cursorToJob(cursor))
            }
        }
        return list
    }

    /**
     * 服务启动时恢复：
     * 将 running 状态的任务视为被杀，转回 queued，由调度器重新排队处理。
     * 返回被恢复的任务列表。
     */
    @Synchronized
    fun recoverRunningJobs(): List<TransferJob> {
        val recovered = mutableListOf<TransferJob>()
        readableDatabase.query(
            TABLE_JOBS,
            null,
            "$COL_STATE = ?",
            arrayOf(JobState.RUNNING.value),
            null,
            null,
            "$COL_CREATED_AT ASC"
        ).use { cursor ->
            while (cursor.moveToNext()) {
                recovered.add(cursorToJob(cursor))
            }
        }

        if (recovered.isNotEmpty()) {
            val now = System.currentTimeMillis()
            val values = ContentValues().apply {
                put(COL_STATE, JobState.QUEUED.value)
                put(COL_UPDATED_AT, now)
            }
            writableDatabase.update(
                TABLE_JOBS,
                values,
                "$COL_STATE = ?",
                arrayOf(JobState.RUNNING.value)
            )
            recovered.forEach {
                it.state = JobState.QUEUED
                it.updatedAt = now
            }
        }
        return recovered
    }

    @Synchronized
    fun deleteJob(jobId: String): Int {
        return writableDatabase.delete(TABLE_JOBS, "$COL_JOB_ID = ?", arrayOf(jobId))
    }

    @Synchronized
    fun deleteJobsByBatch(batchId: String): Int {
        return writableDatabase.delete(TABLE_JOBS, "$COL_BATCH_ID = ?", arrayOf(batchId))
    }

    @Synchronized
    fun clearAll() {
        writableDatabase.delete(TABLE_JOBS, null, null)
    }

    private fun cursorToJob(cursor: android.database.Cursor): TransferJob {
        val jobId = cursor.getString(cursor.getColumnIndexOrThrow(COL_JOB_ID))
        val direction = Direction.fromValue(cursor.getString(cursor.getColumnIndexOrThrow(COL_DIRECTION)))
        val state = JobState.fromValue(cursor.getString(cursor.getColumnIndexOrThrow(COL_STATE)))
        val retryCount = cursor.getInt(cursor.getColumnIndexOrThrow(COL_RETRY_COUNT))
        val batchId = cursor.getString(cursor.getColumnIndexOrThrow(COL_BATCH_ID))
        val category = JobCategory.fromValue(cursor.getString(cursor.getColumnIndexOrThrow(COL_CATEGORY)))
        val createdAt = cursor.getLong(cursor.getColumnIndexOrThrow(COL_CREATED_AT))
        val updatedAt = cursor.getLong(cursor.getColumnIndexOrThrow(COL_UPDATED_AT))
        val fakePlan = cursor.getString(cursor.getColumnIndexOrThrow(COL_FAKE_PLAN))

        return TransferJob(
            jobId = jobId,
            direction = direction,
            state = state,
            retryCount = retryCount,
            batchId = batchId,
            category = category,
            createdAt = createdAt,
            updatedAt = updatedAt,
            fakePlan = fakePlan,
        )
    }
}

