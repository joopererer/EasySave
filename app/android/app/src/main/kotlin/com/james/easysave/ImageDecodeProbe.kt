package com.james.easysave

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.util.Size
import java.io.File
import java.util.concurrent.Executors

/**
 * Device-capability gate for still containers the platform may not decode.
 *
 * Android 12's HEIF decoder rejects some HEIC files an iPhone produced (the
 * ones that carry an alpha auxiliary image): the album thumbnail stays blank,
 * MediaStore metadata extraction stalls and the gallery cannot preview them.
 * A file is only accepted into the album once the platform decoders of *this*
 * device can decode it.
 *
 * The probe never reads a whole picture: bounds first, then a sampled decode
 * whose long side is [SAMPLE_TARGET] pixels. Only [Bitmap] metadata and the
 * sampled bitmap are touched.
 *
 * [decide] and [sampleSizeFor] are Android-free so the decision table is
 * unit-testable without a device; the decode functions below are the thin
 * platform shell around them.
 */
internal object ImageDecodeProbe {
    /** Long side of the probe bitmap, in pixels. */
    const val SAMPLE_TARGET = 256

    /** Why a probe rejected a file; fixed short tokens only (log-safe). */
    const val REASON_OK = "ok"
    const val REASON_UNREADABLE = "unreadable"
    const val REASON_NO_BOUNDS = "no_bounds"
    const val REASON_DECODE_FAILED = "decode_failed"

    const val DECODER_BITMAP_FACTORY = "bitmapfactory"
    const val DECODER_IMAGE_DECODER = "imagedecoder"

    data class Outcome(
        val decodable: Boolean,
        val width: Int,
        val height: Int,
        val sampleWidth: Int,
        val sampleHeight: Int,
        val decoder: String,
        val reason: String,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "decodable" to decodable,
            "width" to width,
            "height" to height,
            "sampleWidth" to sampleWidth,
            "sampleHeight" to sampleHeight,
            "decoder" to decoder,
            "reason" to reason,
        )
    }

    /**
     * Power-of-two `inSampleSize` that brings a [width]x[height] picture under
     * [target] on its long side. 1 means "no down-scaling needed".
     */
    fun sampleSizeFor(width: Int, height: Int, target: Int = SAMPLE_TARGET): Int {
        if (width <= 0 || height <= 0 || target <= 0) return 1
        var sample = 1
        while (width / (sample * 2) >= target || height / (sample * 2) >= target) {
            sample *= 2
        }
        return sample
    }

    /**
     * Decision table of one decoder attempt.
     *
     * * [failure] set: the decoder threw, the file is not decodable by it;
     * * no positive bounds: the container opened but declares no picture;
     * * positive bounds but no sampled pixels: the header parses while the
     *   actual bitstream does not (the alpha-HEIC case on Android 12).
     */
    fun decide(
        boundsWidth: Int,
        boundsHeight: Int,
        sampleWidth: Int,
        sampleHeight: Int,
        decoder: String,
        failure: String? = null,
    ): Outcome {
        val w = if (boundsWidth > 0) boundsWidth else 0
        val h = if (boundsHeight > 0) boundsHeight else 0
        if (failure != null) {
            return Outcome(false, w, h, 0, 0, decoder, failure)
        }
        if (w == 0 || h == 0) {
            return Outcome(false, w, h, 0, 0, decoder, REASON_NO_BOUNDS)
        }
        if (sampleWidth <= 0 || sampleHeight <= 0) {
            return Outcome(false, w, h, 0, 0, decoder, REASON_DECODE_FAILED)
        }
        return Outcome(
            true, w, h, sampleWidth, sampleHeight, decoder, REASON_OK,
        )
    }

    /**
     * Probes [file] with both platform decoders: [BitmapFactory] first (the
     * path the album thumbnail uses), then — only when it fails and the API
     * level has it — [ImageDecoder]. A file counts as decodable when *either*
     * decoder produces pixels, so one decoder's quirk never rejects a picture
     * the device can actually show.
     */
    fun probeFile(file: File): Outcome {
        if (!file.isFile || file.length() <= 0L) {
            return decide(0, 0, 0, 0, DECODER_BITMAP_FACTORY, REASON_UNREADABLE)
        }
        val byFactory = runCatching { probeWithBitmapFactory(file) }
            .getOrElse { decide(0, 0, 0, 0, DECODER_BITMAP_FACTORY, REASON_UNREADABLE) }
        if (byFactory.decodable || Build.VERSION.SDK_INT < 28) return byFactory
        val byDecoder = runCatching { probeWithImageDecoder(file) }
            .getOrElse {
                decide(byFactory.width, byFactory.height, 0, 0, DECODER_IMAGE_DECODER, REASON_DECODE_FAILED)
            }
        return if (byDecoder.decodable) byDecoder else byFactory
    }

    /** Probes an album file by its content URI (history rows store no path). */
    fun probeUri(resolver: android.content.ContentResolver, uri: Uri): Outcome {
        val byFactory = runCatching { probeWithBitmapFactory(resolver, uri) }
            .getOrElse { decide(0, 0, 0, 0, DECODER_BITMAP_FACTORY, REASON_UNREADABLE) }
        if (byFactory.decodable || Build.VERSION.SDK_INT < 28) return byFactory
        val byDecoder = runCatching { probeWithImageDecoder(resolver, uri) }
            .getOrElse {
                decide(byFactory.width, byFactory.height, 0, 0, DECODER_IMAGE_DECODER, REASON_DECODE_FAILED)
            }
        return if (byDecoder.decodable) byDecoder else byFactory
    }

    private fun probeWithBitmapFactory(file: File): Outcome {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            return decide(0, 0, 0, 0, DECODER_BITMAP_FACTORY, REASON_NO_BOUNDS)
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val sampled = BitmapFactory.decodeFile(file.path, options)
            ?: return decide(bounds.outWidth, bounds.outHeight, 0, 0, DECODER_BITMAP_FACTORY, REASON_DECODE_FAILED)
        return sampledOutcome(sampled, bounds.outWidth, bounds.outHeight, DECODER_BITMAP_FACTORY)
    }

    private fun probeWithBitmapFactory(
        resolver: android.content.ContentResolver,
        uri: Uri,
    ): Outcome {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            return decide(0, 0, 0, 0, DECODER_BITMAP_FACTORY, REASON_NO_BOUNDS)
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val sampled = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
            ?: return decide(bounds.outWidth, bounds.outHeight, 0, 0, DECODER_BITMAP_FACTORY, REASON_DECODE_FAILED)
        return sampledOutcome(sampled, bounds.outWidth, bounds.outHeight, DECODER_BITMAP_FACTORY)
    }

    private fun sampledOutcome(
        bitmap: Bitmap,
        width: Int,
        height: Int,
        decoder: String,
    ): Outcome = try {
        decide(width, height, bitmap.width, bitmap.height, decoder)
    } finally {
        runCatching { bitmap.recycle() }
    }

    private fun probeWithImageDecoder(file: File): Outcome {
        if (Build.VERSION.SDK_INT < 28) {
            return decide(0, 0, 0, 0, DECODER_IMAGE_DECODER, REASON_DECODE_FAILED)
        }
        val source = ImageDecoder.createSource(file)
        return decodeSampled { listener ->
            ImageDecoder.decodeBitmap(source, listener)
        }
    }

    private fun probeWithImageDecoder(
        resolver: android.content.ContentResolver,
        uri: Uri,
    ): Outcome {
        if (Build.VERSION.SDK_INT < 28) {
            return decide(0, 0, 0, 0, DECODER_IMAGE_DECODER, REASON_DECODE_FAILED)
        }
        val source = ImageDecoder.createSource(resolver, uri)
        return decodeSampled { listener ->
            ImageDecoder.decodeBitmap(source, listener)
        }
    }

    /** Shared ImageDecoder shell: header size for bounds, then a sampled decode. */
    private fun decodeSampled(
        decode: (ImageDecoder.OnHeaderDecodedListener) -> Bitmap,
    ): Outcome {
        var width = 0
        var height = 0
        val listener = ImageDecoder.OnHeaderDecodedListener { decoder, info, _ ->
            val size: Size = info.size
            width = size.width
            height = size.height
            decoder.setTargetSampleSize(sampleSizeFor(size.width, size.height))
        }
        val bitmap = decode(listener)
        return sampledOutcome(bitmap, width, height, DECODER_IMAGE_DECODER)
    }

    /**
     * One dedicated cached pool: a decode that hangs on one picture must never
     * hold back the next probe, and it must never run on photo_manager's queue,
     * the disk executors or the main thread. Cached (not fixed) on purpose: an
     * abandoned decode keeps its own thread instead of starving the pool.
     */
    private val pool = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "easysave-decode-probe").apply { isDaemon = true }
    }

    fun submit(task: () -> Unit) {
        pool.execute {
            runCatching(task)
        }
    }
}
