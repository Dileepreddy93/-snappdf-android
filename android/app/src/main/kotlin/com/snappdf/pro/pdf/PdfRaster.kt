package com.snappdf.pro.pdf

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.snappdf.pro.OpContext
import com.snappdf.pro.OpError
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Rasterises PDF pages with the platform renderer (PDFium). Encrypted PDFs are
 * first decrypted into a private temporary copy which is deleted on close.
 */
class RasterSession private constructor(
    private val fd: ParcelFileDescriptor,
    val renderer: PdfRenderer,
    private val temp: File?,
) : Closeable {

    val pageCount: Int get() = renderer.pageCount

    /**
     * Renders page [index] so that it is [dpi] dots per inch, limited to
     * [maxPixels] total pixels. Background is white.
     */
    fun render(index: Int, dpi: Float, maxPixels: Long = 24_000_000L): Bitmap {
        if (index !in 0 until pageCount) throw OpError.badArgs("Page ${index + 1} does not exist.")
        renderer.openPage(index).use { page ->
            var scale = dpi / 72f
            var w = (page.width * scale).roundToInt().coerceAtLeast(1)
            var h = (page.height * scale).roundToInt().coerceAtLeast(1)
            if (w.toLong() * h > maxPixels) {
                val f = sqrt(maxPixels.toDouble() / (w.toLong() * h)).toFloat()
                scale *= f
                w = (page.width * scale).roundToInt().coerceAtLeast(1)
                h = (page.height * scale).roundToInt().coerceAtLeast(1)
            }
            val bitmap = try {
                Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            } catch (e: OutOfMemoryError) {
                throw OpError(OpError.OUT_OF_MEMORY, "Not enough memory to render page ${index + 1}.")
            }
            bitmap.eraseColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
            return bitmap
        }
    }

    /** Page size in points as displayed (rotation applied). */
    fun pageSize(index: Int): Pair<Int, Int> = renderer.openPage(index).use { it.width to it.height }

    override fun close() {
        runCatching { renderer.close() }
        runCatching { fd.close() }
        temp?.delete()
    }

    companion object {
        fun open(path: String, password: String?, tempDir: File): RasterSession {
            val file = File(path)
            if (!file.isFile) throw OpError(OpError.IO, "File not found: ${file.name}")
            var temp: File? = null
            val source = PdfDocs.use(path, password) { doc ->
                if (doc.isEncrypted) {
                    tempDir.mkdirs()
                    temp = File.createTempFile("render", ".pdf", tempDir)
                    doc.isAllSecurityToBeRemoved = true
                    doc.save(temp)
                    temp!!
                } else {
                    file
                }
            }
            try {
                val fd = ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
                val renderer = try {
                    PdfRenderer(fd)
                } catch (e: Exception) {
                    fd.close()
                    throw OpError(OpError.INVALID_FILE, "This PDF cannot be rendered.", e)
                }
                return RasterSession(fd, renderer, temp)
            } catch (e: Throwable) {
                temp?.delete()
                throw e
            }
        }
    }
}

object PdfRaster {

    fun writeBitmap(bitmap: Bitmap, output: File, format: String, quality: Int) {
        output.parentFile?.mkdirs()
        val fmt = when (format) {
            "png" -> Bitmap.CompressFormat.PNG
            "webp" -> if (android.os.Build.VERSION.SDK_INT >= 30) Bitmap.CompressFormat.WEBP_LOSSY else @Suppress("DEPRECATION") Bitmap.CompressFormat.WEBP
            else -> Bitmap.CompressFormat.JPEG
        }
        val tmp = File(output.parentFile, ".${output.name}.part")
        FileOutputStream(tmp).use { out ->
            if (!bitmap.compress(fmt, quality.coerceIn(1, 100), out)) throw OpError(OpError.IO, "Could not encode image.")
        }
        if (output.exists()) output.delete()
        if (!tmp.renameTo(output)) throw OpError(OpError.IO, "Could not write ${output.name}.")
    }

    /** Exports pages as images named `<baseName>_<page>.<ext>`. */
    fun toImages(
        path: String, password: String?, pages: List<Int>?, dpi: Float, format: String, quality: Int,
        outDir: String, baseName: String, tempDir: File, ctx: OpContext,
    ): List<String> {
        RasterSession.open(path, password, tempDir).use { session ->
            val indices = PdfDocs.pageIndices(pages, session.pageCount)
            val ext = if (format == "png") "png" else if (format == "webp") "webp" else "jpg"
            val digits = session.pageCount.toString().length
            return indices.mapIndexed { i, index ->
                ctx.checkCancelled()
                ctx.progress(i, indices.size)
                val bitmap = session.render(index, dpi)
                try {
                    val out = File(outDir, "${baseName}_${(index + 1).toString().padStart(digits, '0')}.$ext")
                    writeBitmap(bitmap, out, format, quality)
                    out.path
                } finally {
                    bitmap.recycle()
                }
            }.also { ctx.progress(indices.size, indices.size) }
        }
    }

    /** Renders one page to a PNG/JPEG file fitting [maxWidth] pixels wide. */
    fun renderToFile(path: String, password: String?, page: Int, maxWidth: Int, output: String, tempDir: File): Map<String, Any> {
        RasterSession.open(path, password, tempDir).use { session ->
            val (wPt, _) = session.pageSize(page)
            val dpi = (maxWidth * 72f / wPt.coerceAtLeast(1)).coerceIn(10f, 400f)
            val bitmap = session.render(page, dpi)
            try {
                writeBitmap(bitmap, File(output), if (output.endsWith(".png")) "png" else "jpg", 85)
                return mapOf("path" to output, "width" to bitmap.width, "height" to bitmap.height)
            } finally {
                bitmap.recycle()
            }
        }
    }
}
