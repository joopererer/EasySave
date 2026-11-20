package com.bbflight.background_downloader

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.storage.StorageManager
import android.util.Log
import androidx.core.net.toFile
import androidx.documentfile.provider.DocumentFile
import androidx.preference.PreferenceManager
import com.bbflight.background_downloader.UriUtils.unpack
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import android.system.Os
import android.system.ErrnoException
import kotlin.math.absoluteValue
import kotlin.random.Random
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

class DownloadTaskRunner(context: TaskJobContext) : TaskRunner(context) {

    private fun logV16dl(line: String) {
        Log.i(TAG, "[V16DL] $line")
        try {
            val clazz = Class.forName("com.james.easysave.NativeLog")
            val field = clazz.getDeclaredField("INSTANCE")
            val instance = field.get(null)
            val method = clazz.getDeclaredMethod("i", String::class.java, String::class.java)
            method.invoke(instance, "V16DL", line)
        } catch (_: Throwable) {
            try {
                val logFile = File(context.appContext.filesDir, "v16dl.log")
                logFile.appendText("[INFO] [V16DL] $line\n")
            } catch (_: Throwable) {}
        }
    }

    private var eTagHeader: String? = null
    private var serverAcceptsRanges = false // if true, send resume data on fail
    private var tempFilePath = ""
    private var requiredStartByte = 0L // required start byte within the task range
    private var taskRangeStartByte = 0L // Start of the Task's download range
    private var eTag: String? = null

    /**
     * Make the request to the [connection] and process the [Task]
     *
     * Returns the [TaskStatus]
     * */
    override suspend fun connectAndProcess(connection: HttpURLConnection): TaskStatus {
        if (isResume) {
            val taskRangeHeader = task.headers["Range"] ?: ""
            val taskRange = parseRange(taskRangeHeader)
            taskRangeStartByte = taskRange.first
            val resumeRange = Pair(taskRangeStartByte + requiredStartByte, taskRange.second)
            val newRangeString = "bytes=${resumeRange.first}-${resumeRange.second ?: ""}"
            connection.setRequestProperty("Range", newRangeString)
        }
        val result = super.connectAndProcess(connection)
        if (result == TaskStatus.canceled) {
            logV16dl("native_task_canceled taskId=${task.taskId}")
        }
        if (result == TaskStatus.failed) {
            prepResumeAfterFailure()
        }
        return result
    }

    /** Process the response to the GET or POST request on this [connection]
     *
     * Returns the [TaskStatus]
     */
    override suspend fun process(
        connection: HttpURLConnection,
    ): TaskStatus {
        // Check if the file should be skipped
        val skipThreshold = prefs.getInt(BDPlugin.keyConfigSkipExistingFiles, -1)
        if (skipThreshold != -1) {
            val filePath = task.filePath(context.appContext)
            val file = File(filePath)
            if (file.exists()) {
                val fileSize = file.length()
                if (fileSize > skipThreshold * 1024L * 1024L) {
                    responseStatusCode = 304
                    return TaskStatus.complete
                }
            }
        }

        responseStatusCode = connection.responseCode
        if (connection.responseCode in 300..399 &&
            MediaPolicyRedirects.rules(task.metaData) != null) {
            val host = connection.url.host.lowercase()
            Log.w(TAG, "REQUEST_REDIRECT_REJECTED host=$host")
            taskException = TaskException(ExceptionType.general,
                description = "REQUEST_REDIRECT_REJECTED host=$host")
            return TaskStatus.failed
        }
        if (connection.responseCode in 200..206) {
            // determine if we are using Uri or not.  Uri means pause/resume not allowed
            val directoryUri = UriUtils.uriFromStringValue(task.directory)
            val usesUri = directoryUri != null
            eTagHeader = connection.getHeaderField("ETag")
            val acceptRangesHeader = connection.getHeaderField("Accept-Ranges")
            val explicitlyNoRanges = acceptRangesHeader?.lowercase() == "none"
            serverAcceptsRanges = !explicitlyNoRanges && (
                acceptRangesHeader?.lowercase() == "bytes" ||
                connection.responseCode == 206 ||
                task.allowPause
            )
            val hasEtag = !eTagHeader.isNullOrEmpty()
            val hasLastModified = !connection.getHeaderField("Last-Modified").isNullOrEmpty()
            val contentRangeHeader = connection.getHeaderField("Content-Range")
            var crStart = startByte
            var crTotal = connection.getHeaderField("Content-Length")?.toLongOrNull() ?: -1L
            if (!contentRangeHeader.isNullOrEmpty()) {
                val match = Regex("""bytes\s+(\d+)-(\d+)/(\d+|\*)""").find(contentRangeHeader)
                if (match != null) {
                    crStart = match.groupValues[1].toLongOrNull() ?: startByte
                    val t = match.groupValues[3].toLongOrNull()
                    if (t != null) crTotal = t
                }
            }
            val startByteInfo = if (isResume && connection.responseCode == 206) " content_range_start=$crStart" else ""
            logV16dl(
                "response taskId=${task.taskId} status=${connection.responseCode} " +
                    "accept_ranges=${acceptRangesHeader ?: "none"} has_etag=$hasEtag " +
                    "has_last_modified=$hasLastModified is_resume=$isResume$startByteInfo"
            )
            if (task.allowPause && !usesUri) {
                taskCanResume = serverAcceptsRanges
                processCanResume(
                    task,
                    taskCanResume
                )
            }
            val wasResume = isResume
            isResume = isResume && connection.responseCode == 206  // confirm resume response
            if (wasResume && !isResume) {
                logV16dl(
                    "resume_response taskId=${task.taskId} status=${connection.responseCode} " +
                        "content_range_start=0 content_range_total=$crTotal " +
                        "result=restart reason=status_${connection.responseCode}"
                )
            } else if (isResume) {
                logV16dl(
                    "resume_response taskId=${task.taskId} status=206 " +
                        "content_range_start=$crStart content_range_total=$crTotal " +
                        "result=resumed reason=range_accepted"
                )
            }
            if (isResume && !prepareResume(connection)) {
                val isSizeMismatch = taskException?.description?.contains("size_mismatch") == true
                if (isSizeMismatch) {
                    logV16dl("temp_discard reason=size_mismatch")
                    deleteTempFile()
                }
                val reason = if (isSizeMismatch) "size_mismatch" else "resume_failed"
                logV16dl(
                    "resume_response taskId=${task.taskId} status=${connection.responseCode} " +
                        "content_range_start=0 content_range_total=$crTotal " +
                        "result=restart reason=$reason"
                )
                return TaskStatus.failed
            }
            if (isResume && !eTag.isNullOrEmpty() && (eTagHeader != eTag || eTag?.startsWith("W/") == true)) {
                deleteTempFile()
                Log.i(TAG, "Cannot resume: ETag is not identical, or is weak")
                taskException = TaskException(
                    ExceptionType.resume,
                    description = "Cannot resume: ETag is not identical, or is weak"
                )
                return TaskStatus.failed
            }
            // Determine destination - either [destFilePath] or [destUri]
            // If no filename is set, get from headers or url, and update the task
            var destFilePath = task.filePath(context.appContext)
            var (uriFilename, destUri) = unpack(task.filename)
            if (!task.hasFilename()) {
                // If no filename is set, get from headers or url, and update the task
                if (usesUri) {
                    uriFilename = suggestFilename(connection.headerFields, task.url)
                    if (uriFilename.isEmpty()) {
                        uriFilename = "${Random.nextInt().absoluteValue}"
                    }
                    task = task.copyWith(
                        filename = if (destUri == null) uriFilename else UriUtils.pack(
                            uriFilename,
                            destUri
                        )
                    )
                } else {
                    destFilePath = destFilePath(connection)
                }
            }
            extractResponseHeaders(connection.headerFields)
            extractContentType(connection.headerFields)
            val contentLength = getContentLength(connection.headerFields, task)
            // determine tempFile, or set to null if Uri is used
            val tempFile = if (!usesUri) {
                val applicationSupportPath =
                    baseDirPath(context.appContext, BaseDirectory.applicationSupport)
                val cachePath = baseDirPath(context.appContext, BaseDirectory.temporary)
                if (applicationSupportPath == null || cachePath == null) {
                    throw IllegalStateException("External storage is requested but not available")
                }
                val sharedPrefs = PreferenceManager.getDefaultSharedPreferences(context.appContext)
                val tempFilePathConfig = sharedPrefs.getString(BDPlugin.keyConfigTempFilePath, null)
                val tempDir = if (!tempFilePathConfig.isNullOrEmpty()) {
                    File(tempFilePathConfig)
                } else {
                    when (sharedPrefs.getInt(BDPlugin.keyConfigUseCacheDir, -2)) {
                        0 -> File(cachePath) // 'always'
                        -1 -> File(applicationSupportPath) // 'never'
                        else -> {
                            // 'whenAble' -> determine based on cache quota
                            val storageManager =
                                context.appContext.getSystemService(Context.STORAGE_SERVICE) as StorageManager
                            val cacheQuota = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                storageManager.getCacheQuotaBytes(
                                    storageManager.getUuidForPath(
                                        File(cachePath)
                                    )
                                )
                            } else {
                                50L shl (20)  // for older OS versions, assume 50MB
                            }
                            if (contentLength < cacheQuota / 2) File(cachePath) else File(
                                applicationSupportPath
                            )
                        }
                    }
                }
                if (!tempDir.exists()) {
                    tempDir.mkdirs()
                }
                tempFilePath =
                    tempFilePath.ifEmpty { "${tempDir.absolutePath}/com.bbflight.background_downloader${Random.nextInt()}" }

                // confirm enough storage space for download
                if (insufficientSpace(context.appContext, contentLength)) {
                    Log.i(
                        TAG,
                        "Insufficient space to store the file to be downloaded for taskId ${task.taskId}"
                    )
                    taskException = TaskException(
                        ExceptionType.fileSystem,
                        description = "Insufficient space to store the file to be downloaded"
                    )
                    return TaskStatus.failed
                }
                val f = File(tempFilePath)
                if (f.exists() && f.length() > 0L && !isResume) {
                    val reason = if (connection.responseCode == 200) "status_200" else "no_range"
                    logV16dl("temp_discard reason=$reason")
                    f.delete()
                }
                f
            } else {
                null
            }
            val outputStream: java.io.OutputStream = if (tempFile != null) {
                FileOutputStream(tempFile, isResume)
            } else {
                // no tempFile, because we have a Uri
                uriFilename = uriFilename ?: "unknown"
                if (directoryUri!!.scheme == "file") {
                    // fileUri is converted to a File, then to a FileOutputStream
                    if (destUri == null) {
                        // need to create file at directory
                        val dirObject = directoryUri.toFile()
                        val destFile = File(dirObject, uriFilename)
                        destUri = Uri.fromFile(destFile)
                        // Store destination Uri in task
                        task = task.copyWith(filename = UriUtils.pack(uriFilename, destUri))
                        FileOutputStream(destFile) // return outputStream
                    } else {
                        // use destination Uri that was set in previous attempt
                        FileOutputStream(destUri.toFile())
                    }
                } else {
                    // other URL scheme will be attempted to resolve using content resolver
                    val resolver = context.appContext.contentResolver
                    // create destination Uri if not already exists
                    val documentFile = DocumentFile.fromTreeUri(context.appContext, directoryUri)
                    destUri = destUri ?: documentFile?.createFile(task.mimeType, uriFilename)?.uri
                    if (destUri == null) {
                        val message =
                            "Failed to create document within directory with URI: $directoryUri"
                        Log.e(TAG, message)
                        taskException = TaskException(
                            ExceptionType.fileSystem,
                            description = message
                        )
                        return TaskStatus.failed
                    }
                    val newFilename = getFilenameFromUri(destUri)
                    if (newFilename.isNotEmpty()) {
                        uriFilename = newFilename
                    }
                    task = task.copyWith(filename = UriUtils.pack(uriFilename, destUri))
                    val os = resolver.openOutputStream(destUri)
                    if (os == null) {
                        val message = "Failed to open output stream for URI: $destUri"
                        Log.e(TAG, message)
                        taskException = TaskException(
                            ExceptionType.fileSystem,
                            description = message
                        )
                        return TaskStatus.failed
                    } else os
                }
            }
            BDPlugin.remainingBytesToDownload[task.taskId] = contentLength
            determineRunInForeground(task, contentLength) // sets 'runInForeground'
            context.updateEstimatedNetworkBytes(contentLength, 0L)
            // transfer the bytes from the server to the output stream
            val transferBytesResult: TaskStatus
            BufferedInputStream(connection.inputStream).use { inputStream ->
                transferBytesResult = transferBytes(
                    inputStream, outputStream, contentLength, task
                )
            }
            outputStream.flush()
            outputStream.close()
            // act on the result of the bytes transfer
            when (transferBytesResult) {
                TaskStatus.complete -> {
                    if (tempFile == null) {
                        Log.i(
                            TAG, "Successfully downloaded taskId ${task.taskId} to URI $destUri"
                        )
                    } else {
                        // move file from its temp location to the destination
                        val destFile = File(destFilePath)
                        val dir = destFile.parentFile!!
                        if (!dir.exists()) {
                            dir.mkdirs()
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            withContext(Dispatchers.IO) {
                                try {
                                    Files.move(
                                        tempFile.toPath(),
                                        destFile.toPath(),
                                        StandardCopyOption.REPLACE_EXISTING
                                    )
                                } catch (e: java.nio.file.FileSystemException) {
                                    // Fallback if moving across different filesystems/mount points (EXDEV / Cross-device link)
                                    Log.d(TAG, "Files.move failed ($e), falling back to copyTo + delete")
                                    tempFile.copyTo(destFile, overwrite = true)
                                    deleteTempFile()
                                }
                            }
                            setFileOwnership(destFile)
                        } else {
                            tempFile.copyTo(destFile, overwrite = true)
                            deleteTempFile()
                            setFileOwnership(destFile)
                        }
                        Log.i(
                            TAG, "Successfully downloaded taskId ${task.taskId} to $destFilePath"
                        )
                    }
                    return TaskStatus.complete
                }

                TaskStatus.canceled -> {
                    cleanup(usesUri, destUri)
                    Log.i(TAG, "Canceled taskId ${task.taskId}")
                    return TaskStatus.canceled
                }

                TaskStatus.paused -> {
                    BDPlugin.pausedTaskIds.remove(task.taskId)
                    if (taskCanResume) {
                        Log.i(TAG, "Task ${task.taskId} paused")
                        processResumeData(
                            ResumeData(
                                task, tempFilePath, bytesTotal + startByte, eTagHeader
                            ), prefs
                        )
                        return TaskStatus.paused
                    }
                    if (BDPlugin.tasksToReEnqueue.contains(task) && serverAcceptsRanges) {
                        // pause was triggered by re-enqueue request due to WiFi requirement change
                        // so we only store local resumeData without posting it
                        Log.i(TAG, "Task ${task.taskId} paused in order to re-enqueue")
                        BDPlugin.localResumeData[task.taskId] = ResumeData(
                            task, tempFilePath, bytesTotal + startByte, eTagHeader
                        )
                        return TaskStatus.paused
                    }
                    Log.i(TAG, "Task ${task.taskId} cannot resume, therefore pause failed")
                    taskException = TaskException(
                        ExceptionType.resume,
                        description = "Task was paused but cannot resume"
                    )
                    cleanup(usesUri, destUri)
                    return TaskStatus.failed
                }

                TaskStatus.enqueued -> {
                    // Special status: task timed out.
                    // For resumable tasks, post resume data so App initiates the new round with Range.
                    if (taskCanResume) {
                        val start = bytesTotal + startByte
                        processResumeData(
                            ResumeData(task, tempFilePath, start, eTagHeader),
                            prefs
                        )
                    }
                    taskException = TaskException(
                        ExceptionType.connection,
                        description = "Task timed out"
                    )
                    cleanup(usesUri, destUri)
                    return TaskStatus.failed
                }

                TaskStatus.failed -> {
                    prepResumeAfterFailure()
                    return TaskStatus.failed
                }

                else -> {
                    Log.e(TAG, "Unknown transferBytesResult $transferBytesResult")
                    cleanup(usesUri, destUri)
                    return TaskStatus.failed
                }
            }
        } else {
            // HTTP response code not OK
            Log.i(
                TAG,
                "Response code ${connection.responseCode} for taskId ${task.taskId}"
            )
            val errorContent = responseErrorContent(connection)
            taskException = TaskException(
                ExceptionType.httpResponse, httpResponseCode = connection.responseCode,
                description = if (errorContent?.isNotEmpty() == true) errorContent else connection.responseMessage
            )
            return if (connection.responseCode == 404) {
                responseBody = errorContent
                TaskStatus.notFound
            } else {
                TaskStatus.failed
            }
        }
    }

    /**
     * Return destination filePath where the filename is set based on response headers, and
     * update the [task] accordingly
     */
    private fun destFilePath(connection: HttpURLConnection): String {
        val destFilePath = task.filePath(context.appContext)
        task = task.withSuggestedFilenameFromResponseHeaders(
            context.appContext,
            connection.headerFields,
            unique = true
        )
        val dirName = File(destFilePath).parent ?: ""
        return if (dirName.isEmpty()) task.filename else "$dirName/${task.filename}"
    }


    /**
     * Return true if this is a resume, and resume is possible,
     * given [tempFilePath] and [requiredStartByte]
     * */
    override fun determineIfResume(): Boolean {
        // set tempFilePath from resume data, or "" if a new tempFile is needed
        requiredStartByte = context.getInputLong(keyStartByte, 0)
        if (requiredStartByte == 0L) {
            return false
        }
        eTag = context.getInputString(keyETag)
        tempFilePath = if (requiredStartByte > 0) context.getInputString(keyResumeDataData) ?: ""
        else ""
        val tempFile = File(tempFilePath)
        if (tempFile.exists()) {
            val tempFileLength = tempFile.length()
            if (tempFileLength == requiredStartByte) {
                return true
            } else if (tempFileLength > 0) {
                val effectiveStart = maxOf(requiredStartByte, tempFileLength)
                Log.i(TAG, "Adjusting requiredStartByte from $requiredStartByte to on-disk length $effectiveStart (tempFileLength=$tempFileLength)")
                requiredStartByte = effectiveStart
                return true
            } else {
                Log.i(TAG, "Partially downloaded file is corrupted, resume not possible")
            }
        } else {
            Log.i(TAG, "Partially downloaded file not available, resume not possible")
        }
        return false
    }

    /** Prepare for resume if possible
     *
     * Returns true if task can continue, false if task failed.
     * Extracts and parses Range headers, and truncates temp file
     */
    private fun prepareResume(connection: HttpURLConnection): Boolean {
        if (tempFilePath.isEmpty()) {
            return false
        }
        val range = connection.getHeaderField("Content-Range")
        if (range == null) {
            Log.i(
                TAG, "Could not " +
                        "process partial response Content-Range: header missing"
            )
            return false
        }
        val contentRangeRegEx = Regex("(\\d+)-(\\d+)/(\\d+)")
        val matchResult = contentRangeRegEx.find(range)
        if (matchResult == null) {
            Log.i(TAG, "Could not process partial response Content-Range $range")
            taskException = TaskException(
                ExceptionType.resume,
                description = "Could not process partial response Content-Range $range"
            )
            return false
        }
        val start = matchResult.groups[1]?.value?.toLong()!!
        val serverTotal = matchResult.groups[3]?.value?.toLongOrNull()
        val expectedTotal = try {
            if (task.metaData.isNotEmpty()) {
                val json = Json.parseToJsonElement(task.metaData).jsonObject
                json["expectedBytes"]?.jsonPrimitive?.longOrNull
            } else null
        } catch (_: Exception) {
            null
        }
        if (expectedTotal != null && expectedTotal > 0 && serverTotal != null && serverTotal != expectedTotal) {
            Log.w(TAG, "Content-Range total $serverTotal does not match expected total $expectedTotal for taskId ${task.taskId}")
            taskException = TaskException(
                ExceptionType.resume,
                description = "size_mismatch: server total $serverTotal != expected $expectedTotal"
            )
            return false
        }
        val tempFile = File(tempFilePath)
        val tempFileLength = tempFile.length()
        startByte = start - taskRangeStartByte // relative to start of range
        if (startByte > tempFileLength) {
            Log.i(TAG, "Offered range not feasible: $range with startByte $startByte")
            taskException = TaskException(
                ExceptionType.resume,
                description = "Offered range not feasible: $range with startByte $startByte"
            )
            return false
        }
        // resume possible, set start conditions
        try {
            RandomAccessFile(tempFilePath, "rw").use { it.setLength(startByte) }
        } catch (_: IOException) {
            Log.i(TAG, "Could not truncate temp file")
            taskException =
                TaskException(
                    ExceptionType.resume,
                    description = "Could not truncate temp file"
                )
            return false
        }
        return true
    }

    /**
     * Attempt to allow resume after failure by sending resume data
     * back to Dart
     *
     * If this is not possible, the temp file will be deleted
     */
    private suspend fun prepResumeAfterFailure() {
        val tempFile = if (tempFilePath.isNotEmpty()) File(tempFilePath) else null
        val tempExists = tempFile?.exists() ?: false
        val tempSize = if (tempExists) tempFile?.length() ?: 0L else 0L
        val hasEtag = !eTagHeader.isNullOrEmpty()

        Log.i(
            TAG,
            "[V16DL] failure_callback taskId=${task.taskId} " +
                "status=failed exception_type=${taskException?.type ?: "none"} " +
                "server_accepts_ranges=$serverAcceptsRanges " +
                "bytes_total=$bytesTotal start_byte=$startByte " +
                "temp_exists=$tempExists temp_size=$tempSize " +
                "has_etag=$hasEtag"
        )

        val canResume = (serverAcceptsRanges && (bytesTotal + startByte > 1 shl 20 || (task.allowPause && tempSize > 0))) || (tempSize > 0)
        if (canResume) {
            // if failure can be resumed, post resume data
            val resumeBytes = if (bytesTotal + startByte > 0) bytesTotal + startByte else tempSize
            processResumeData(
                ResumeData(
                    task, tempFilePath, resumeBytes, eTagHeader
                ), prefs
            )
        } else if (responseStatusCode in listOf(403, 410) && (requiredStartByte > 0 || isResume)) {
            // Signed URL expired during resume; keep temp file and resume data so App can reparse and resume
            Log.i(TAG, "Signed URL expired (status $responseStatusCode) for taskId ${task.taskId}, keeping temp file for reparse")
        } else {
            // Only delete if temp file is empty or 0 bytes
            if (tempSize == 0L) {
                deleteTempFile()
            } else {
                Log.i(TAG, "Preserving partial temp file (${tempSize} bytes) despite failure for taskId ${task.taskId}")
            }
        }
    }

    /**
     * Deletes the temp file associated with this download
     */
    private fun deleteTempFile() {
        if (tempFilePath.isNotEmpty()) {
            try {
                val tempFile = File(tempFilePath)
                tempFile.delete()
            } catch (_: IOException) {
                Log.i(TAG, "Could not delete temp file at $tempFilePath")
            }
        }
    }

    /**
     * Deletes the destination Uri at [uri]
     */
    private fun deleteDestinationUri(uri: Uri) {
        try {
            context.appContext.contentResolver.delete(uri, null, null)
        } catch (_: Exception) {
            Log.i(TAG, "Could not delete file at $uri")
        }
    }

    /**
     * Cleanup by deleting the temp file or destination uri
     */
    private fun cleanup(usesUri: Boolean, destUri: Uri?) {
        if (usesUri && destUri != null) {
            deleteDestinationUri(destUri)
        } else {
            deleteTempFile()
        }
    }

    /**
     * Sets the group ownership of the downloaded file.
     *
     * Determines the app's GID and then calls Os.chown. Logs success or failure.
     * Likely to fail if the file is in external storage.
     *
     * Reason for changing ownership os to unmark file as a cache file (issue #498)
     */
    private fun setFileOwnership(destFile: File) {
        try {
            val finalPath = destFile.absolutePath
            val gid = context.appContext.applicationInfo.uid // App's own GID
            Os.chown(finalPath, -1, gid) // -1 for UID means keep current owner
        } catch (e: ErrnoException) {
            // Log the error, common if the filesystem doesn't support chown or due to permissions.
            // Check OsConstants for specific errno values if needed.
            Log.w(
                TAG,
                "Failed to change group ownership for ${destFile.absolutePath}: ${e.message}"
            )
        }
    }

}
