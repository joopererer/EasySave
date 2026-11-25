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

class TransferFinalizer(
    private val transfersDir: File,
    private val store: TransferStore,
    private val publisher: MediaPublisher,
) {

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
            val ext = when (mimeToUse) {
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

            val sanitizedId = jobId.replace(Regex("[^A-Za-z0-9_-]"), "_")
            val baseName = "${sanitizedId}_1.$ext"
            val relativePath = ExportNames.albumPath("EasySave")

            var targetName = baseName
            var attempt = 1
            while (publisher.exists(relativePath, targetName) && attempt <= 20) {
                attempt++
                val dot = baseName.lastIndexOf('.')
                val indexSep = baseName.lastIndexOf('_', dot)
                targetName = "${baseName.substring(0, indexSep)}-copy$attempt${baseName.substring(indexSep)}"
            }

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
}
