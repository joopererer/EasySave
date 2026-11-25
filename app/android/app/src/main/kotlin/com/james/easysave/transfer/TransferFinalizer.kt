package com.james.easysave.transfer

import android.os.Looper
import com.james.easysave.ExportNames
import com.james.easysave.MediaImportPolicy
import com.james.easysave.provenance.ProvenanceEmbedder
import com.james.easysave.provenance.ProvenanceReader
import com.james.easysave.provenance.ProvenanceRecord
import com.james.easysave.provenance.StreamingFileRewriter
import java.io.File

sealed class FinalizeOutcome {
    data class Success(
        val publishedMedia: PublishedMedia,
        val partSha256: String?,
        val provenanceStatus: String,
        val readbackMatch: Boolean,
        val verifyMs: Long,
        val provenanceMs: Long,
        val importMs: Long,
        val readbackMs: Long,
        val bytesRead: Long = 0L,
        val bytesWritten: Long = 0L,
        val readbackBytes: Long = 0L,
    ) : FinalizeOutcome()

    data class Failed(
        val reason: String,
        val cause: Throwable? = null,
    ) : FinalizeOutcome()
}

data class PairFinalizeItem(
    val job: TransferJob,
    val meta: TransferMeta,
    val partFile: File,
)

sealed class PairFinalizeOutcome {
    data class Success(val outcomes: Map<String, FinalizeOutcome.Success>) : PairFinalizeOutcome()
    data class Failed(
        val reason: String,
        val cause: Throwable? = null,
    ) : PairFinalizeOutcome()
}

class SimulatedKillException(message: String = "simulated_kill") : RuntimeException(message)

class TransferFinalizer(
    private val transfersDir: File,
    private val store: TransferStore,
    private val publisher: MediaPublisher,
) {
    internal var onStageForTesting: ((jobId: String, stage: String) -> Unit)? = null

    fun execute(
        job: TransferJob,
        meta: TransferMeta,
        partFile: File,
    ): FinalizeOutcome {
        // 主线程断言：收尾严禁占用主线程
        val isMain = try {
            Looper.myLooper() == Looper.getMainLooper()
        } catch (_: Throwable) {
            false
        }
        check(!isMain) { "TransferFinalizer must run on background thread" }

        val jobId = job.jobId
        val vStart = System.currentTimeMillis()

        if (!partFile.exists()) {
            // 没有物理文件（例如 FakeWorker / 纯调度虚拟测试用例）
            val dummyMedia = PublishedMedia(
                mediaId = "mock_${jobId}",
                title = "${jobId.replace(Regex("[^A-Za-z0-9_-]"), "_")}_1.jpg",
                relativePath = ExportNames.albumPath("EasySave"),
                md5 = "d41d8cd98f00b204e9800998ecf8427e",
                size = 0L,
                thread = "bg"
            )
            job.finalizeStep = "published"
            job.mediaId = dummyMedia.mediaId
            job.title = dummyMedia.title
            job.md5 = dummyMedia.md5
            job.provenanceStatus = "none"
            job.historyPending = true
            store.updateJobFinalizeProgress(
                jobId,
                finalizeStep = "published",
                mediaId = dummyMedia.mediaId,
                title = dummyMedia.title,
                md5 = dummyMedia.md5,
                provenanceStatus = "none",
                historyPending = true
            )
            return FinalizeOutcome.Success(
                publishedMedia = dummyMedia,
                partSha256 = null,
                provenanceStatus = "none",
                readbackMatch = true,
                verifyMs = 0L,
                provenanceMs = 0L,
                importMs = 0L,
                readbackMs = 0L,
                bytesRead = 0L,
                bytesWritten = 0L,
                readbackBytes = 0L,
            )
        }

        // 1. 校验 (Validation: 长度 stat + 魔数 sniff，不读全文件)
        if (meta.total > 0 && partFile.exists() && partFile.length() != meta.total) {
            TransferLog.e("job=${TransferLog.shortId(jobId)} length_mismatch expected=${meta.total} actual=${partFile.length()}")
            return FinalizeOutcome.Failed("length_mismatch")
        }

        val sniffedMime = MediaSniffer.sniff(partFile)
        val expectedMime = meta.mime ?: meta.sniff
        if (!MediaSniffer.matches(expectedMime, sniffedMime)) {
            TransferLog.e("job=${TransferLog.shortId(jobId)} sniff_mismatch expected=$expectedMime sniffed=$sniffedMime")
            return FinalizeOutcome.Failed("sniff_mismatch")
        }

        val verifyMs = System.currentTimeMillis() - vStart
        job.verifyMs = verifyMs
        store.updateJobFinalizeProgress(jobId, verifyMs = verifyMs)

        // 2. 检查被杀恢复状态
        val currentStep = job.finalizeStep
        if (currentStep?.startsWith("inserted:") == true) {
            val pendingMediaId = currentStep.substringAfter("inserted:")
            TransferLog.i("job=${TransferLog.shortId(jobId)} kill_recovery: deleting pending mediaId=$pendingMediaId")
            publisher.deletePending(pendingMediaId)
            job.finalizeStep = null
            store.updateJobFinalizeProgress(jobId, finalizeStep = null, mediaId = null)
        }

        // 3. 一遍写入：相册插入与流式写入（同时嵌入来源信息与计算 MD5，无 .final 文件）
        val pStart = System.currentTimeMillis()
        val publishedMedia: PublishedMedia
        val mimeToUse = sniffedMime ?: "image/jpeg"
        val isEmbeddable = MediaImportPolicy.provenanceEmbeddable(mimeToUse)
        var provenanceStatus = job.provenanceStatus ?: if (!isEmbeddable) "skipped_unsupported" else "none"

        if (job.finalizeStep != "published") {
            val ext = extensionForMime(mimeToUse, partFile)
            val targetName = resolveTargetName(jobId, meta, ext, ExportNames.albumPath("EasySave"))
            val relativePath = ExportNames.albumPath("EasySave")

            val handle = try {
                publisher.insertPending(relativePath, targetName, mimeToUse, partFile)
            } catch (t: Throwable) {
                TransferLog.e("job=${TransferLog.shortId(jobId)} insertPending failed: ${t.message}", t)
                return FinalizeOutcome.Failed("insert_failed", t)
            }

            job.finalizeStep = "inserted:${handle.mediaId}"
            job.mediaId = handle.mediaId
            job.title = handle.displayName
            store.updateJobFinalizeProgress(
                jobId,
                finalizeStep = "inserted:${handle.mediaId}",
                mediaId = handle.mediaId,
                title = handle.displayName
            )

            val writeResult: StreamingFileRewriter.WriteResult
            try {
                publisher.openOutputStream(handle).use { outStream ->
                    if (isEmbeddable && meta.provenance != null) {
                        val record = ProvenanceRecord.fromMap(meta.provenance)
                        provenanceStatus = "embedded"
                        writeResult = ProvenanceEmbedder.embedToStream(partFile, outStream, record)
                    } else {
                        provenanceStatus = if (!isEmbeddable) "skipped_unsupported" else "none"
                        writeResult = StreamingFileRewriter.copyToStream(partFile, outStream)
                    }
                }
            } catch (t: Throwable) {
                TransferLog.e("job=${TransferLog.shortId(jobId)} single-pass write failed: ${t.message}", t)
                publisher.deletePending(handle.mediaId)
                return FinalizeOutcome.Failed("write_failed", t)
            }

            publishedMedia = try {
                publisher.publish(handle, writeResult.md5Hex, writeResult.bytesWritten, mimeToUse)
            } catch (t: Throwable) {
                TransferLog.e("job=${TransferLog.shortId(jobId)} publish failed: ${t.message}", t)
                publisher.deletePending(handle.mediaId)
                return FinalizeOutcome.Failed("publish_failed", t)
            }

            val importMs = System.currentTimeMillis() - pStart
            val provenanceMs = 0L // 一遍写入，无独立来源信息中间文件重写耗时

            job.finalizeStep = "published"
            job.md5 = publishedMedia.md5
            job.fileSize = publishedMedia.size
            job.provenanceStatus = provenanceStatus
            job.importMs = importMs
            job.provenanceMs = provenanceMs
            store.updateJobFinalizeProgress(
                jobId,
                finalizeStep = "published",
                md5 = publishedMedia.md5,
                fileSize = publishedMedia.size,
                provenanceStatus = provenanceStatus,
                importMs = importMs,
                provenanceMs = provenanceMs,
            )
        } else {
            // 已发布状态被杀恢复
            val prevMediaId = job.mediaId ?: "recovered_$jobId"
            publishedMedia = PublishedMedia(
                mediaId = prevMediaId,
                title = job.title ?: "recovered_$jobId",
                relativePath = ExportNames.albumPath("EasySave"),
                md5 = job.md5 ?: "",
                size = job.fileSize,
                thread = "bg"
            )
        }

        // 4. 回读校验 (Readback Verification: 按 MP4 box / segment / chunk 定位，跳过数据块)
        val rStart = System.currentTimeMillis()
        var readbackOk = true
        var readbackBytes = 0L
        if (provenanceStatus == "embedded" && meta.provenance != null) {
            val record = ProvenanceRecord.fromMap(meta.provenance)
            try {
                publisher.openSeekableInput(publishedMedia.mediaId).use { seekable ->
                    readbackOk = ProvenanceReader.verify(seekable, record.assetId, record.platform)
                    readbackBytes = seekable.bytesRead
                }
                if (!readbackOk) {
                    TransferLog.e("job=${TransferLog.shortId(jobId)} readback verification failed for assetId=${record.assetId}")
                    return FinalizeOutcome.Failed("readback_mismatch")
                }
            } catch (t: Throwable) {
                TransferLog.e("job=${TransferLog.shortId(jobId)} readback failed: ${t.message}", t)
                return FinalizeOutcome.Failed("readback_error", t)
            }
        }
        val readbackMs = System.currentTimeMillis() - rStart
        job.readbackMs = readbackMs
        job.readbackMatch = readbackOk
        store.updateJobFinalizeProgress(jobId, readbackMs = readbackMs, readbackMatch = readbackOk)

        // 5. 结果写入 Store，清理临时文件
        job.historyPending = true
        store.updateJobFinalizeProgress(jobId, historyPending = true)

        val bytesRead = if (partFile.exists()) partFile.length() else publishedMedia.size
        val bytesWritten = publishedMedia.size

        try { partFile.delete() } catch (_: Throwable) {}
        try { File(transfersDir, "$jobId.final").delete() } catch (_: Throwable) {}
        try { File(transfersDir, "$jobId.meta").delete() } catch (_: Throwable) {}

        // 6. 日志输出（包含 bytes_read、bytes_written、readback_bytes 字段）
        val md5Prefix = publishedMedia.md5.take(8)
        TransferLog.i("[XFER] finish_timing job=${TransferLog.shortId(jobId)} verify_ms=$verifyMs provenance_ms=${job.provenanceMs} import_ms=${job.importMs} readback_ms=$readbackMs bytes_read=$bytesRead bytes_written=$bytesWritten readback_bytes=$readbackBytes md5=$md5Prefix provenance=$provenanceStatus thread=bg")

        return FinalizeOutcome.Success(
            publishedMedia = publishedMedia,
            partSha256 = job.partSha256,
            provenanceStatus = provenanceStatus,
            readbackMatch = readbackOk,
            verifyMs = verifyMs,
            provenanceMs = job.provenanceMs,
            importMs = job.importMs,
            readbackMs = readbackMs,
            bytesRead = bytesRead,
            bytesWritten = bytesWritten,
            readbackBytes = readbackBytes,
        )
    }

    private fun extensionForMime(mime: String, partFile: File): String = when (mime) {
        "image/jpeg" -> "jpg"
        "image/png" -> "png"
        "image/webp" -> "webp"
        "image/gif" -> "gif"
        "image/heic", "image/heif" -> "heic"
        "image/avif" -> "avif"
        "video/mp4" -> "mp4"
        "video/quicktime" -> "mov"
        else -> partFile.extension.ifEmpty { "jpg" }
    }

    private fun resolveTargetName(jobId: String, meta: TransferMeta, ext: String, relativePath: String): String {
        val record = meta.provenance?.let { runCatching { ProvenanceRecord.fromMap(it) }.getOrNull() }
        val sourceId = record?.sourceId?.takeIf { it.isNotBlank() && Regex("^[A-Za-z0-9_-]+$").matches(it) }
        val itemIndex = record?.itemIndex?.takeIf { it >= 1 } ?: 1
        val baseName = if (sourceId != null) {
            "${sourceId}_${itemIndex}.$ext"
        } else {
            val sanitizedId = jobId.replace(Regex("[^A-Za-z0-9_-]"), "_")
            "${sanitizedId}_1.$ext"
        }

        var targetName = baseName
        var attempt = 1
        while (publisher.exists(relativePath, targetName) && attempt <= 20) {
            attempt++
            val dot = baseName.lastIndexOf('.')
            val indexSep = baseName.lastIndexOf('_', dot)
            targetName = "${baseName.substring(0, indexSep)}-copy$attempt${baseName.substring(indexSep)}"
        }
        return targetName
    }

    private data class PairPendingEntry(
        val item: PairFinalizeItem,
        val handle: PublishedHandle,
        val writeResult: StreamingFileRewriter.WriteResult,
        val mimeToUse: String,
        val provenanceStatus: String,
        val importStartMs: Long,
    )

    fun executePair(items: List<PairFinalizeItem>): PairFinalizeOutcome {
        val isMain = try {
            Looper.myLooper() == Looper.getMainLooper()
        } catch (_: Throwable) {
            false
        }
        check(!isMain) { "TransferFinalizer must run on background thread" }
        require(items.isNotEmpty()) { "Pair items must not be empty" }

        val relativePath = ExportNames.albumPath("EasySave")
        val sniffedMimes = mutableMapOf<String, String>()
        val verifyMsMap = mutableMapOf<String, Long>()

        // 1. 校验全部成员（stat 长度 + 魔数）
        for (item in items) {
            val jobId = item.job.jobId
            val vStart = System.currentTimeMillis()
            if (item.partFile.exists()) {
                if (item.meta.total > 0 && item.partFile.length() != item.meta.total) {
                    TransferLog.e("job=${TransferLog.shortId(jobId)} pair length_mismatch expected=${item.meta.total} actual=${item.partFile.length()}")
                    return PairFinalizeOutcome.Failed("length_mismatch")
                }
                val sniffedMime = MediaSniffer.sniff(item.partFile)
                val expectedMime = item.meta.mime ?: item.meta.sniff
                if (!MediaSniffer.matches(expectedMime, sniffedMime)) {
                    TransferLog.e("job=${TransferLog.shortId(jobId)} pair sniff_mismatch expected=$expectedMime sniffed=$sniffedMime")
                    return PairFinalizeOutcome.Failed("sniff_mismatch")
                }
                sniffedMimes[jobId] = sniffedMime ?: "image/jpeg"
            } else {
                sniffedMimes[jobId] = item.meta.mime ?: "image/jpeg"
            }
            val vMs = System.currentTimeMillis() - vStart
            verifyMsMap[jobId] = vMs
            item.job.verifyMs = vMs
            store.updateJobFinalizeProgress(jobId, verifyMs = vMs)
        }

        // 2. 被杀恢复检查：未发布的（inserted:*）全部删除并重置后重做；已发布的保留等待同伴
        for (item in items) {
            val job = item.job
            val step = job.finalizeStep
            if (step?.startsWith("inserted:") == true) {
                val pendingMediaId = step.substringAfter("inserted:")
                TransferLog.i("job=${TransferLog.shortId(job.jobId)} pair kill_recovery: deleting pending mediaId=$pendingMediaId")
                publisher.deletePending(pendingMediaId)
                job.finalizeStep = null
                job.mediaId = null
                job.title = null
                store.clearFinalizeProgress(job.jobId)
            }
        }

        val pendingEntries = mutableMapOf<String, PairPendingEntry>()
        val publishedMap = mutableMapOf<String, PublishedMedia>()
        val provenanceStatusMap = mutableMapOf<String, String>()

        for (item in items) {
            val job = item.job
            if (job.finalizeStep == "published") {
                val prevId = job.mediaId ?: "recovered_${job.jobId}"
                publishedMap[job.jobId] = PublishedMedia(
                    mediaId = prevId,
                    title = job.title ?: "recovered_${job.jobId}",
                    relativePath = relativePath,
                    md5 = job.md5 ?: "",
                    size = job.fileSize,
                    thread = "bg"
                )
                provenanceStatusMap[job.jobId] = job.provenanceStatus ?: "none"
            }
        }

        fun rollbackAll() {
            for ((jobId, entry) in pendingEntries) {
                runCatching { publisher.deletePending(entry.handle.mediaId) }
                items.firstOrNull { it.job.jobId == jobId }?.job?.let {
                    it.finalizeStep = null
                    it.mediaId = null
                    it.title = null
                }
                store.clearFinalizeProgress(jobId)
            }
            for ((jobId, pub) in publishedMap) {
                runCatching { publisher.deletePending(pub.mediaId) }
                items.firstOrNull { it.job.jobId == jobId }?.job?.let {
                    it.finalizeStep = null
                    it.mediaId = null
                    it.title = null
                }
                store.clearFinalizeProgress(jobId)
            }
        }

        // 3. 对未发布成员执行 IS_PENDING 插入 + 一遍流式写入（全部写完前不 publish）
        for (item in items) {
            val job = item.job
            if (job.finalizeStep == "published") continue

            val mimeToUse = sniffedMimes[job.jobId] ?: "image/jpeg"
            val isEmbeddable = MediaImportPolicy.provenanceEmbeddable(mimeToUse)
            val importStartMs = System.currentTimeMillis()
            val ext = extensionForMime(mimeToUse, item.partFile)
            val targetName = resolveTargetName(job.jobId, item.meta, ext, relativePath)

            val handle = try {
                publisher.insertPending(relativePath, targetName, mimeToUse, item.partFile)
            } catch (t: Throwable) {
                TransferLog.e("job=${TransferLog.shortId(job.jobId)} pair insertPending failed: ${t.message}", t)
                rollbackAll()
                return PairFinalizeOutcome.Failed("insert_failed", t)
            }

            job.finalizeStep = "inserted:${handle.mediaId}"
            job.mediaId = handle.mediaId
            job.title = handle.displayName
            store.updateJobFinalizeProgress(
                job.jobId,
                finalizeStep = "inserted:${handle.mediaId}",
                mediaId = handle.mediaId,
                title = handle.displayName,
            )
            onStageForTesting?.invoke(job.jobId, "after_insert")

            val provStatus: String
            val writeResult: StreamingFileRewriter.WriteResult
            try {
                if (!item.partFile.exists()) {
                    provStatus = "none"
                    writeResult = StreamingFileRewriter.WriteResult(0L, "d41d8cd98f00b204e9800998ecf8427e")
                } else {
                    publisher.openOutputStream(handle).use { outStream ->
                        if (isEmbeddable && item.meta.provenance != null) {
                            val record = ProvenanceRecord.fromMap(item.meta.provenance)
                            provStatus = "embedded"
                            writeResult = ProvenanceEmbedder.embedToStream(item.partFile, outStream, record)
                        } else {
                            provStatus = if (!isEmbeddable) "skipped_unsupported" else "none"
                            writeResult = StreamingFileRewriter.copyToStream(item.partFile, outStream)
                        }
                    }
                }
            } catch (t: SimulatedKillException) {
                throw t
            } catch (t: Throwable) {
                TransferLog.e("job=${TransferLog.shortId(job.jobId)} pair single-pass write failed: ${t.message}", t)
                runCatching { publisher.deletePending(handle.mediaId) }
                job.finalizeStep = null
                job.mediaId = null
                job.title = null
                store.clearFinalizeProgress(job.jobId)
                rollbackAll()
                return PairFinalizeOutcome.Failed("write_failed", t)
            }

            provenanceStatusMap[job.jobId] = provStatus
            pendingEntries[job.jobId] = PairPendingEntry(
                item = item,
                handle = handle,
                writeResult = writeResult,
                mimeToUse = mimeToUse,
                provenanceStatus = provStatus,
                importStartMs = importStartMs,
            )
        }

        // 4. 全部写完后，一起发布（IS_PENDING = 0）
        for (item in items) {
            val job = item.job
            if (job.finalizeStep == "published") continue
            val entry = pendingEntries.getValue(job.jobId)

            val published = try {
                publisher.publish(entry.handle, entry.writeResult.md5Hex, entry.writeResult.bytesWritten, entry.mimeToUse)
            } catch (t: SimulatedKillException) {
                throw t
            } catch (t: Throwable) {
                TransferLog.e("job=${TransferLog.shortId(job.jobId)} pair publish failed: ${t.message}", t)
                rollbackAll()
                return PairFinalizeOutcome.Failed("publish_failed", t)
            }

            val importMs = System.currentTimeMillis() - entry.importStartMs
            job.finalizeStep = "published"
            job.md5 = published.md5
            job.fileSize = published.size
            job.provenanceStatus = entry.provenanceStatus
            job.importMs = importMs
            job.provenanceMs = 0L
            store.updateJobFinalizeProgress(
                job.jobId,
                finalizeStep = "published",
                md5 = published.md5,
                fileSize = published.size,
                provenanceStatus = entry.provenanceStatus,
                importMs = importMs,
                provenanceMs = 0L,
            )
            publishedMap[job.jobId] = published
            pendingEntries.remove(job.jobId)
            onStageForTesting?.invoke(job.jobId, "after_publish")
        }

        // 5. 回读校验（全部成员）
        val outcomes = mutableMapOf<String, FinalizeOutcome.Success>()
        for (item in items) {
            val job = item.job
            val published = publishedMap.getValue(job.jobId)
            val provStatus = provenanceStatusMap[job.jobId] ?: "none"
            val rStart = System.currentTimeMillis()
            var readbackOk = true
            var readbackBytes = 0L

            if (provStatus == "embedded" && item.meta.provenance != null && item.partFile.exists()) {
                val record = ProvenanceRecord.fromMap(item.meta.provenance)
                try {
                    publisher.openSeekableInput(published.mediaId).use { seekable ->
                        readbackOk = ProvenanceReader.verify(seekable, record.assetId, record.platform)
                        readbackBytes = seekable.bytesRead
                    }
                    if (!readbackOk) {
                        TransferLog.e("job=${TransferLog.shortId(job.jobId)} pair readback verification failed")
                        rollbackAll()
                        return PairFinalizeOutcome.Failed("readback_mismatch")
                    }
                } catch (t: Throwable) {
                    TransferLog.e("job=${TransferLog.shortId(job.jobId)} pair readback error: ${t.message}", t)
                    rollbackAll()
                    return PairFinalizeOutcome.Failed("readback_error", t)
                }
            }

            val readbackMs = System.currentTimeMillis() - rStart
            job.readbackMs = readbackMs
            job.readbackMatch = readbackOk
            job.historyPending = true
            store.updateJobFinalizeProgress(
                job.jobId,
                readbackMs = readbackMs,
                readbackMatch = readbackOk,
                historyPending = true,
            )

            val bytesRead = if (item.partFile.exists()) item.partFile.length() else published.size
            val bytesWritten = published.size

            outcomes[job.jobId] = FinalizeOutcome.Success(
                publishedMedia = published,
                partSha256 = job.partSha256,
                provenanceStatus = provStatus,
                readbackMatch = readbackOk,
                verifyMs = verifyMsMap[job.jobId] ?: 0L,
                provenanceMs = 0L,
                importMs = job.importMs,
                readbackMs = readbackMs,
                bytesRead = bytesRead,
                bytesWritten = bytesWritten,
                readbackBytes = readbackBytes,
            )
        }

        // 6. 清理临时文件并打印耗时日志
        for (item in items) {
            val job = item.job
            val outcome = outcomes.getValue(job.jobId)
            try { item.partFile.delete() } catch (_: Throwable) {}
            try { File(transfersDir, "${job.jobId}.final").delete() } catch (_: Throwable) {}
            try { File(transfersDir, "${job.jobId}.meta").delete() } catch (_: Throwable) {}
            val md5Prefix = outcome.publishedMedia.md5.take(8)
            TransferLog.i("[XFER] finish_timing pairId=${job.pairId} job=${TransferLog.shortId(job.jobId)} verify_ms=${outcome.verifyMs} provenance_ms=0 import_ms=${outcome.importMs} readback_ms=${outcome.readbackMs} bytes_read=${outcome.bytesRead} bytes_written=${outcome.bytesWritten} readback_bytes=${outcome.readbackBytes} md5=$md5Prefix provenance=${outcome.provenanceStatus} thread=bg")
        }

        return PairFinalizeOutcome.Success(outcomes)
    }
}
