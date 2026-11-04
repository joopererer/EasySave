package com.james.easysave

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Looper
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayInputStream

/** All panel decodes share sampling and the complete EXIF dihedral transform. */
internal object OrientedBitmap {
    fun decode(bytes: ByteArray, target: Int, label: String = "unbound"): Bitmap? {
        check(Looper.myLooper() != Looper.getMainLooper())
        val orientation = ByteArrayInputStream(bytes).use {
            ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1)
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val swapped = orientation in 5..8
        val width = if (swapped) bounds.outHeight else bounds.outWidth
        val height = if (swapped) bounds.outWidth else bounds.outHeight
        if (width <= 0 || height <= 0) return null
        var sample = 1
        while (width / (sample * 2) >= target && height / (sample * 2) >= target) sample *= 2
        val image = BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.RGB_565 }) ?: return null
        val matrix = Matrix().apply { setValues(orientationMatrix(orientation)) }
        val transformed = Bitmap.createBitmap(image, 0, 0, image.width, image.height, matrix, true)
        if (transformed !== image) image.recycle()
        NativeLog.i("PreviewImage", "event=orientation orientation=$orientation storedWidth=${bounds.outWidth} storedHeight=${bounds.outHeight} shownWidth=${transformed.width} shownHeight=${transformed.height} sample=$sample thread=bg key=$label")
        return transformed
    }
}

/** Translation is normalized by Bitmap.createBitmap after transforming bounds. */
internal fun orientationMatrix(orientation: Int): FloatArray {
    val linear = when (orientation) {
        2 -> floatArrayOf(-1f, 0f, 0f, 1f)
        3 -> floatArrayOf(-1f, 0f, 0f, -1f)
        4 -> floatArrayOf(1f, 0f, 0f, -1f)
        5 -> floatArrayOf(0f, 1f, 1f, 0f)
        6 -> floatArrayOf(0f, -1f, 1f, 0f)
        7 -> floatArrayOf(0f, -1f, -1f, 0f)
        8 -> floatArrayOf(0f, 1f, -1f, 0f)
        else -> floatArrayOf(1f, 0f, 0f, 1f)
    }
    return floatArrayOf(linear[0], linear[1], 0f, linear[2], linear[3], 0f, 0f, 0f, 1f)
}
