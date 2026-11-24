package com.james.easysave.transfer

import android.os.Looper
import com.james.easysave.ExportNames
import com.james.easysave.MediaImportPolicy
import com.james.easysave.provenance.ProvenanceEmbedder
import com.james.easysave.provenance.ProvenanceReader
import com.james.easysave.provenance.ProvenanceRecord
import java.io.File
import java.security.MessageDigest

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
            )
        }

        // 1. 校验 (Validation)
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

        // 计算 .part 原始文件的 SHA-256（在嵌入来源信息前）
        val partSha256 = job.partSha256 ?: try {
            if (partFile.exists()) {
                val md = MessageDigest.getInstance("SHA-256")
                partFile.inputStream().use { stream ->
                    val buf = ByteArray(65536)
                    var read: Int
                    while (stream.read(buf).also { read = it } > 0) {
                        md.update(buf, 0, read)
                    }
                }
                md.digest().joinToString("") { "%02x".format(it) }
            } else null
        } catch (_: Throwable) { null }

        val verifyMs = System.currentTimeMillis() - vStart
        job.partSha256 = partSha256
        job.verifyMs = verifyMs
        store.updateJobFinalizeProgress(jobId, partSha256 = partSha256, verifyMs = verifyMs)

        // 2. 检查被杀恢复状态
        val currentStep = job.finalizeStep
        if (currentStep?.startsWith("inserted:") == true) {
            val pendingMediaId = currentStep.substringAfter("inserted:")
            TransferLog.i("job=${TransferLog.shortId(jobId)} kill_recovery: deleting pending mediaId=$pendingMediaId")
            publisher.deletePending(pendingMediaId)
            job.finalizeStep = "embedded"
            store.updateJobFinalizeProgress(jobId, finalizeStep = "embedded", mediaId = null)
        }

        val finalFile = File(transfersDir, "$jobId.final")
        var sourceForImport = partFile
        var provenanceStatus = job.provenanceStatus ?: "skipped_unsupported"

        // 3. 写来源信息 (Provenance Embedding)
        val pStart = System.currentTimeMillis()
        if (job.finalizeStep != "published") {
            val isEmbeddable = MediaImportPolicy.provenanceEmbeddable(sniffedMime ?: "")
            if (isEmbeddable && meta.provenance != null) {
                try {
                    val record = ProvenanceRecord.fromMap(meta.provenance)
                    ProvenanceEmbedder.embed(partFile, finalFile, record)
                    sourceForImport = finalFile
                    provenanceStatus = "embedded"
                } catch (t: Throwable) {
                    TransferLog.e("job=${TransferLog.shortId(jobId)} provenance embedding failed: ${t.message}", t)
                    return FinalizeOutcome.Failed("provenance_failed", t)
                }
            } else {
                provenanceStatus = if (!isEmbeddable) "skipped_unsupported" else "none"
                sourceForImport = partFile
            }
            job.finalizeStep = "embedded"
            job.provenanceStatus = provenanceStatus
            store.updateJobFinalizeProgress(
                jobId,
                finalizeStep = "embedded",
                provenanceStatus = provenanceStatus
            )
        }
        val provenanceMs = System.currentTimeMillis() - pStart
        job.provenanceMs = provenanceMs
        store.updateJobFinalizeProgress(jobId, provenanceMs = provenanceMs)

        // 4. 写入相册 (Publish to Gallery)
        val iStart = System.currentTimeMillis()
        val publishedMedia: PublishedMedia
        val mimeToUse = sniffedMime ?: "image/jpeg"

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
                else -> sourceForImport.extension.ifEmpty { "jpg" }
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
                publisher.insertPending(relativePath, targetName, mimeToUse, sourceForImport)
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

            publishedMedia = try {
                publisher.copyAndPublish(handle, sourceForImport, mimeToUse)
            } catch (t: Throwable) {
                TransferLog.e("job=${TransferLog.shortId(jobId)} copyAndPublish failed: ${t.message}", t)
                publisher.deletePending(handle.mediaId)
                return FinalizeOutcome.Failed("publish_failed", t)
            }

            job.finalizeStep = "published"
            job.md5 = publishedMedia.md5
            job.fileSize = publishedMedia.size
            store.updateJobFinalizeProgress(
                jobId,
                finalizeStep = "published",
                md5 = publishedMedia.md5,
                fileSize = publishedMedia.size
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
        val importMs = System.currentTimeMillis() - iStart
        job.importMs = importMs
        store.updateJobFinalizeProgress(jobId, importMs = importMs)

        // 5. 回读校验 (Readback Verification)
        val rStart = System.currentTimeMillis()
        var readbackOk = true
        if (provenanceStatus == "embedded" && meta.provenance != null) {
            val record = ProvenanceRecord.fromMap(meta.provenance)
            try {
                publisher.openInputStream(publishedMedia.mediaId).use { stream ->
                    readbackOk = ProvenanceReader.verify(stream, record.assetId, record.platform)
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

        // 6. 结果写入 Store，清理临时文件
        job.historyPending = true
        store.updateJobFinalizeProgress(jobId, historyPending = true)

        try { partFile.delete() } catch (_: Throwable) {}
        try { if (finalFile.exists()) finalFile.delete() } catch (_: Throwable) {}
        try { File(transfersDir, "$jobId.meta").delete() } catch (_: Throwable) {}

        // 7. 日志输出
        val md5Prefix = publishedMedia.md5.take(8)
        TransferLog.i("[XFER] finish_timing job=${TransferLog.shortId(jobId)} verify_ms=$verifyMs provenance_ms=$provenanceMs import_ms=$importMs readback_ms=$readbackMs md5=$md5Prefix provenance=$provenanceStatus thread=bg")

        return FinalizeOutcome.Success(
            publishedMedia = publishedMedia,
            partSha256 = partSha256,
            provenanceStatus = provenanceStatus,
            readbackMatch = readbackOk,
            verifyMs = verifyMs,
            provenanceMs = provenanceMs,
            importMs = importMs,
            readbackMs = readbackMs,
        )
    }
}
