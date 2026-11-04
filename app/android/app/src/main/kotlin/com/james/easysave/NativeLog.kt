package com.james.easysave

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.RandomAccessFile
import java.io.File
import java.util.concurrent.locks.ReentrantLock

/** Native diagnostics sink shared with Dart's application-support DevLog. */
internal object NativeLog {
    @Volatile private var appContext: Context? = null
    private const val fileName = "v16dl.log"
    private val url = Regex("""https?://[^\s"'<>]+""")
    private val secret = Regex(
        """(?i)(cookie|set-cookie|authorization|token|password|secret|session|sig)\s*[:=]\s*[^\s,;)]+"""
    )

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        init(context)
        MethodChannel(messenger, "easysave/dev_log").setMethodCallHandler { call, result ->
            try {
                val writer = NativeLogFileWriter(File(context.filesDir, fileName))
                when (call.method) {
                    "append" -> writer.append(call.arguments as String)
                    "clear" -> writer.clear()
                    "export" -> {
                        val target = context.getExternalFilesDir(null)?.let { File(it, fileName) }
                        result.success(target?.let { writer.export(it) })
                        return@setMethodCallHandler
                    }
                    else -> { result.notImplemented(); return@setMethodCallHandler }
                }
                result.success(null)
            } catch (_: Exception) {
                result.error("LOG_IO", "Log operation failed", null)
            }
        }
        i("NativeLog", "event=ready sink=files/v16dl.log transport=easysave/dev_log")
    }

    fun i(tag: String, message: String) = write(Log.INFO, tag, message)
    fun w(tag: String, message: String, error: Throwable? = null) =
        write(Log.WARN, tag, message, error)
    fun e(tag: String, message: String, error: Throwable? = null) =
        write(Log.ERROR, tag, message, error)

    private fun write(priority: Int, tag: String, message: String, error: Throwable? = null) {
        val safe = url.replace(secret.replace(message) { "${it.value.substringBefore('=')}=<redacted>" }) {
            runCatching {
                val uri = java.net.URI(it.value)
                "${uri.host}${uri.path ?: ""}"
            }.getOrDefault("<url>")
        }
        Log.println(priority, tag, safe)
        val context = appContext ?: return
        runCatching {
            val dir = context.filesDir
            if (!dir.exists()) dir.mkdirs()
            NativeLogFileWriter(File(dir, fileName)).append(
                "[${if (priority >= Log.ERROR) "ERROR" else if (priority >= Log.WARN) "WARN" else "INFO"}] [$tag] $safe\n"
            )
        }
    }
}

internal class NativeLogFileWriter(
    private val file: File,
) {
    private companion object {
        val processLock = ReentrantLock()
    }

    fun append(line: String) {
        locked {
            val bytes = (line.trimEnd('\r', '\n').replace("\r", "\\r").replace("\n", "\\n") + "\n")
                .toByteArray(Charsets.UTF_8)
            if (file.exists() && file.length() + bytes.size > 1024 * 1024) {
                val backup = File("${file.path}.1")
                if (backup.exists()) check(backup.delete())
                check(file.renameTo(backup))
            }
            RandomAccessFile(file, "rw").use { output ->
                output.seek(output.length())
                output.write(bytes)
                output.fd.sync()
            }
        }
    }

    fun clear() = locked {
        file.delete()
        File("${file.path}.1").delete()
    }

    fun export(target: File): String? = locked {
        if (!file.exists()) null else {
            file.copyTo(target, overwrite = true)
            target.path
        }
    }

    private fun <T> locked(action: () -> T): T {
        val lockFile = File("${file.path}.lock")
        lockFile.parentFile?.mkdirs()
        processLock.lock()
        try {
            RandomAccessFile(lockFile, "rw").use { lockHandle ->
                lockHandle.channel.lock().use {
                    return action()
                }
            }
        } finally {
            processLock.unlock()
        }
    }
}
