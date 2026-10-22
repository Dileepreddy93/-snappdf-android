package com.snappdf.pro.ml

import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import com.snappdf.pro.OpError
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteOrder
import java.util.concurrent.ExecutionException

/**
 * Person/background separation with ML Kit selfie segmentation (bundled
 * model). Designed for portraits; other subjects are not reliably separated.
 */
object Segmenter {
    private val segmenter by lazy {
        Segmentation.getClient(
            SelfieSegmenterOptions.Builder()
                .setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE)
                .enableRawSizeMask()
                .build(),
        )
    }

    /**
     * Writes an 8-bit mask (white = person) as PNG at the upright image's size
     * (up to 2048 px) and returns its path and dimensions.
     */
    fun personMask(imagePath: String, output: String): Map<String, Any> {
        val bitmap = Ocr.decodeUpright(imagePath, 2048)
        try {
            val mask = try {
                Tasks.await(segmenter.process(InputImage.fromBitmap(bitmap, 0)))
            } catch (e: ExecutionException) {
                throw OpError(OpError.UNAVAILABLE, "Background detection failed: ${e.cause?.message ?: e.message}", e)
            }
            val mw = mask.width
            val mh = mask.height
            val buffer = mask.buffer.order(ByteOrder.nativeOrder()).asFloatBuffer()
            val pixels = IntArray(mw * mh)
            var personPixels = 0
            for (i in 0 until mw * mh) {
                val v = (buffer.get(i).coerceIn(0f, 1f) * 255f).toInt()
                if (v > 127) personPixels++
                pixels[i] = (0xFF shl 24) or (v shl 16) or (v shl 8) or v
            }
            var maskBitmap = Bitmap.createBitmap(pixels, mw, mh, Bitmap.Config.ARGB_8888)
            if (mw != bitmap.width || mh != bitmap.height) {
                val scaled = Bitmap.createScaledBitmap(maskBitmap, bitmap.width, bitmap.height, true)
                maskBitmap.recycle()
                maskBitmap = scaled
            }
            File(output).parentFile?.mkdirs()
            FileOutputStream(output).use { maskBitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            maskBitmap.recycle()
            return mapOf(
                "path" to output,
                "width" to bitmap.width,
                "height" to bitmap.height,
                "coverage" to personPixels.toDouble() / (mw * mh),
            )
        } finally {
            bitmap.recycle()
        }
    }
}
