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
        const val DB_VERSION = 4
        const val TABLE_JOBS = "transfer_jobs"

        const val COL_JOB_ID = "job_id"
        const val COL_DIRECTION = "direction"
        const val COL_STATE = "state"
        const val COL_RETRY_COUNT = "retry_count"
        const val COL_BATCH_ID = "batch_id"
        const val COL_PAIR_ID = "pair_id"
        const val COL_CATEGORY = "category"
        const val COL_CREATED_AT = "created_at"
        const val COL_UPDATED_AT = "updated_at"
        const val COL_FAKE_PLAN = "fake_plan"

        const val COL_FINALIZE_STEP = "finalize_step"
        const val COL_MEDIA_ID = "media_id"
        const val COL_TITLE = "title"
        const val COL_RELATIVE_PATH = "relative_path"
        const val COL_MD5 = "md5"
        const val COL_FILE_SIZE = "file_size"
        const val COL_PART_SHA256 = "part_sha256"
        const val COL_VERIFY_MS = "verify_ms"
        const val COL_PROVENANCE_MS = "provenance_ms"
        const val COL_IMPORT_MS = "import_ms"
        const val COL_READBACK_MS = "readback_ms"
        const val COL_PROVENANCE_STATUS = "provenance_status"
        const val COL_READBACK_MATCH = "readback_match"
        const val COL_HISTORY_PENDING = "history_pending"
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
                $COL_PAIR_ID TEXT,
                $COL_CATEGORY TEXT NOT NULL,
                $COL_CREATED_AT INTEGER NOT NULL,
                $COL_UPDATED_AT INTEGER NOT NULL,
                $COL_FAKE_PLAN TEXT,
                $COL_FINALIZE_STEP TEXT,
                $COL_MEDIA_ID TEXT,
                $COL_TITLE TEXT,
                $COL_RELATIVE_PATH TEXT,
                $COL_MD5 TEXT,
                $COL_FILE_SIZE INTEGER NOT NULL DEFAULT 0,
                $COL_PART_SHA256 TEXT,
                $COL_VERIFY_MS INTEGER NOT NULL DEFAULT 0,
                $COL_PROVENANCE_MS INTEGER NOT NULL DEFAULT 0,
                $COL_IMPORT_MS INTEGER NOT NULL DEFAULT 0,
                $COL_READBACK_MS INTEGER NOT NULL DEFAULT 0,
                $COL_PROVENANCE_STATUS TEXT,
                $COL_READBACK_MATCH INTEGER,
                $COL_HISTORY_PENDING INTEGER NOT NULL DEFAULT 0
            )
            """.trimIndent()
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_FINALIZE_STEP TEXT")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_MEDIA_ID TEXT")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_TITLE TEXT")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_MD5 TEXT")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_FILE_SIZE INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_PART_SHA256 TEXT")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_VERIFY_MS INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_PROVENANCE_MS INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_IMPORT_MS INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_READBACK_MS INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_PROVENANCE_STATUS TEXT")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_READBACK_MATCH INTEGER")
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_HISTORY_PENDING INTEGER NOT NULL DEFAULT 0")
        }
        if (oldVersion < 3) {
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_PAIR_ID TEXT")
        }
        if (oldVersion < 4) {
            db.execSQL("ALTER TABLE $TABLE_JOBS ADD COLUMN $COL_RELATIVE_PATH TEXT")
        }
    }

    @Synchronized
    fun insertOrReplace(job: TransferJob) {
        val values = ContentValues().apply {
            put(COL_JOB_ID, job.jobId)
            put(COL_DIRECTION, job.direction.value)
            put(COL_STATE, job.state.value)
            put(COL_RETRY_COUNT, job.retryCount)
            put(COL_BATCH_ID, job.batchId)
            put(COL_PAIR_ID, job.pairId)
            put(COL_CATEGORY, job.category.value)
            put(COL_CREATED_AT, job.createdAt)
            put(COL_UPDATED_AT, job.updatedAt)
            put(COL_FAKE_PLAN, job.fakePlan)
            put(COL_FINALIZE_STEP, job.finalizeStep)
            put(COL_MEDIA_ID, job.mediaId)
            put(COL_TITLE, job.title)
            put(COL_RELATIVE_PATH, job.relativePath)
            put(COL_MD5, job.md5)
            put(COL_FILE_SIZE, job.fileSize)
            put(COL_PART_SHA256, job.partSha256)
            put(COL_VERIFY_MS, job.verifyMs)
            put(COL_PROVENANCE_MS, job.provenanceMs)
            put(COL_IMPORT_MS, job.importMs)
            put(COL_READBACK_MS, job.readbackMs)
            put(COL_PROVENANCE_STATUS, job.provenanceStatus)
            put(COL_READBACK_MATCH, job.readbackMatch?.let { if (it) 1 else 0 })
            put(COL_HISTORY_PENDING, if (job.historyPending) 1 else 0)
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
    fun getHistoryPendingJobs(): List<TransferJob> {
        val list = mutableListOf<TransferJob>()
        readableDatabase.query(
            TABLE_JOBS,
            null,
            "$COL_STATE = ? AND $COL_HISTORY_PENDING = 1",
            arrayOf(JobState.DONE.value),
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
    fun clearHistoryPending(jobIds: List<String>) {
        if (jobIds.isEmpty()) return
        val values = ContentValues().apply {
            put(COL_HISTORY_PENDING, 0)
            put(COL_UPDATED_AT, System.currentTimeMillis())
        }
        val placeholders = jobIds.joinToString(",") { "?" }
        writableDatabase.update(
            TABLE_JOBS,
            values,
            "$COL_JOB_ID IN ($placeholders)",
            jobIds.toTypedArray()
        )
    }

    private val historyClaims = mutableMapOf<String, Long>()

    @Synchronized
    fun claimHistoryWrite(
        batchId: String,
        nowMs: Long = System.currentTimeMillis(),
        timeoutMs: Long = 60_000L,
    ): Boolean {
        val claimedAt = historyClaims[batchId]
        if (claimedAt != null && (nowMs - claimedAt) < timeoutMs) {
            return false
        }
        historyClaims[batchId] = nowMs
        return true
    }

    @Synchronized
    fun clearAll() {
        writableDatabase.delete(TABLE_JOBS, null, null)
    }

    @Synchronized
    fun updateJobFinalizeProgress(
        jobId: String,
        finalizeStep: String? = null,
        mediaId: String? = null,
        title: String? = null,
        relativePath: String? = null,
        md5: String? = null,
        fileSize: Long? = null,
        partSha256: String? = null,
        verifyMs: Long? = null,
        provenanceMs: Long? = null,
        importMs: Long? = null,
        readbackMs: Long? = null,
        provenanceStatus: String? = null,
        readbackMatch: Boolean? = null,
        historyPending: Boolean? = null,
        updatedAt: Long = System.currentTimeMillis(),
    ) {
        val values = ContentValues().apply {
            put(COL_UPDATED_AT, updatedAt)
            if (finalizeStep != null) put(COL_FINALIZE_STEP, finalizeStep)
            if (mediaId != null) put(COL_MEDIA_ID, mediaId)
            if (title != null) put(COL_TITLE, title)
            if (relativePath != null) put(COL_RELATIVE_PATH, relativePath)
            if (md5 != null) put(COL_MD5, md5)
            if (fileSize != null) put(COL_FILE_SIZE, fileSize)
            if (partSha256 != null) put(COL_PART_SHA256, partSha256)
            if (verifyMs != null) put(COL_VERIFY_MS, verifyMs)
            if (provenanceMs != null) put(COL_PROVENANCE_MS, provenanceMs)
            if (importMs != null) put(COL_IMPORT_MS, importMs)
            if (readbackMs != null) put(COL_READBACK_MS, readbackMs)
            if (provenanceStatus != null) put(COL_PROVENANCE_STATUS, provenanceStatus)
            if (readbackMatch != null) put(COL_READBACK_MATCH, if (readbackMatch) 1 else 0)
            if (historyPending != null) put(COL_HISTORY_PENDING, if (historyPending) 1 else 0)
        }
        writableDatabase.update(
            TABLE_JOBS,
            values,
            "$COL_JOB_ID = ?",
            arrayOf(jobId)
        )
    }

    @Synchronized
    fun clearFinalizeProgress(jobId: String, updatedAt: Long = System.currentTimeMillis()) {
        val values = ContentValues().apply {
            put(COL_UPDATED_AT, updatedAt)
            putNull(COL_FINALIZE_STEP)
            putNull(COL_MEDIA_ID)
            putNull(COL_TITLE)
            putNull(COL_MD5)
            put(COL_FILE_SIZE, 0L)
        }
        writableDatabase.update(
            TABLE_JOBS,
            values,
            "$COL_JOB_ID = ?",
            arrayOf(jobId)
        )
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

        fun optString(col: String): String? {
            val idx = cursor.getColumnIndex(col)
            return if (idx >= 0 && !cursor.isNull(idx)) cursor.getString(idx) else null
        }
        fun optLong(col: String, def: Long = 0L): Long {
            val idx = cursor.getColumnIndex(col)
            return if (idx >= 0 && !cursor.isNull(idx)) cursor.getLong(idx) else def
        }
        fun optBoolean(col: String): Boolean? {
            val idx = cursor.getColumnIndex(col)
            return if (idx >= 0 && !cursor.isNull(idx)) cursor.getInt(idx) == 1 else null
        }

        return TransferJob(
            jobId = jobId,
            direction = direction,
            state = state,
            retryCount = retryCount,
            batchId = batchId,
            pairId = optString(COL_PAIR_ID),
            category = category,
            createdAt = createdAt,
            updatedAt = updatedAt,
            fakePlan = fakePlan,
            finalizeStep = optString(COL_FINALIZE_STEP),
            mediaId = optString(COL_MEDIA_ID),
            title = optString(COL_TITLE),
            relativePath = optString(COL_RELATIVE_PATH),
            md5 = optString(COL_MD5),
            fileSize = optLong(COL_FILE_SIZE),
            partSha256 = optString(COL_PART_SHA256),
            verifyMs = optLong(COL_VERIFY_MS),
            provenanceMs = optLong(COL_PROVENANCE_MS),
            importMs = optLong(COL_IMPORT_MS),
            readbackMs = optLong(COL_READBACK_MS),
            provenanceStatus = optString(COL_PROVENANCE_STATUS),
            readbackMatch = optBoolean(COL_READBACK_MATCH),
            historyPending = optBoolean(COL_HISTORY_PENDING) ?: false,
        )
    }
}

