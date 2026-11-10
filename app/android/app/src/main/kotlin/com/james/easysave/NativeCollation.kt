package com.james.easysave

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.text.Collator
import java.util.Locale

/**
 * Locale-aware name ordering for the history creator list.
 *
 * Dart has no collation, so Chinese names would otherwise be ordered by code
 * point. java.text.Collator (ICU) returns the system collation key, which for
 * a Chinese locale is pinyin order. Keys are encoded so comparing them as
 * strings matches comparing the raw key bytes unsigned, and no name leaves the
 * device. The channel needs no Activity; it only reads the current locale.
 */
class NativeCollation {
    companion object {
        const val CHANNEL = "easysave/text"

        fun keysFor(names: List<String>, locale: Locale): List<String> {
            val collator = Collator.getInstance(locale)
            return names.map { name -> encode(collator.getCollationKey(name).toByteArray()) }
        }

        private const val DIGITS = "0123456789abcdef"

        private fun encode(bytes: ByteArray): String {
            val out = StringBuilder(bytes.size * 2)
            for (byte in bytes) {
                val value = byte.toInt() and 0xFF
                out.append(DIGITS[value ushr 4]).append(DIGITS[value and 0x0F])
            }
            return out.toString()
        }

        fun register(messenger: BinaryMessenger) {
            MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "collationKeys" -> {
                        val names = call.argument<List<String>>("names") ?: emptyList()
                        try {
                            result.success(keysFor(names, Locale.getDefault()))
                        } catch (e: Exception) {
                            result.error("COLLATION_FAILED", e.javaClass.simpleName, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}