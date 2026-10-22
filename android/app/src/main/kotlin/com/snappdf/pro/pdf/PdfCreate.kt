package com.snappdf.pro.pdf

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import androidx.exifinterface.media.ExifInterface
import com.snappdf.pro.OpContext
import com.snappdf.pro.OpError
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.LosslessFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import java.io.File
import kotlin.math.max
import kotlin.math.min

object PdfCreate {

    data class ImagePdfOptions(
        /** "a4", "letter" or "fit" (page follows the image's aspect ratio). */
        val pageSize: String = "a4",
        /** "auto", "portrait" or "landscape". */
        val orientation: String = "auto",
        val margin: Float = 0f,
        /** "original" (no recompression of JPEGs), "high" or "medium". */
        val quality: String = "original",
    )

    /** Max pixel dimension for 32-bit bitmaps decoded here (~ 64 MB). */
    private const val MAX_DECODE_PIXELS = 16_000_000L

    fun imagesToPdf(images: List<String>, output: String, opts: ImagePdfOptions, ctx: OpContext) {
        if (images.isEmpty()) throw OpError.badArgs("Select at least one image.")
        PDDocument().use { doc ->
            images.forEachIndexed { i, path ->
                ctx.checkCancelled()
                ctx.progress(i, images.size, File(path).name)
                addImagePage(doc, File(path), opts)
            }
            ctx.progress(images.size, images.size)
            doc.documentInformation.producer = "SnapPDF"
            PdfDocs.save(doc, output)
        }
    }

    private class Prepared(val image: PDImageXObject, val rotation: Int, val mirror: Boolean)

    private fun addImagePage(doc: PDDocument, file: File, opts: ImagePdfOptions) {
        if (!file.isFile) throw OpError(OpError.IO, "Image not found: ${file.name}")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw OpError(OpError.INVALID_FILE, "${file.name} is not a supported image.")
        }
        val (rotation, mirror) = exifRotation(file)
        val prepared = prepareImage(doc, file, bounds, rotation, mirror, opts)
        // Displayed (upright) image size.
        val swap = prepared.rotation % 180 != 0
        val imgW = (if (swap) prepared.image.height else prepared.image.width).toFloat()
        val imgH = (if (swap) prepared.image.width else prepared.image.height).toFloat()
        val landscapeImage = imgW > imgH

        val page = when (opts.pageSize) {
            "fit" -> {
                val w = if (landscapeImage) 842f else 595f
                PDPage(PDRectangle(w + 2 * opts.margin, w * imgH / imgW + 2 * opts.margin))
            }
            else -> {
                val base = if (opts.pageSize == "letter") PDRectangle.LETTER else PDRectangle.A4
                val landscape = when (opts.orientation) {
                    "landscape" -> true
                    "portrait" -> false
                    else -> landscapeImage
                }
                PDPage(if (landscape) PDRectangle(base.height, base.width) else PDRectangle(base.width, base.height))
            }
        }
        doc.addPage(page)
        val g = PdfDocs.geometry(page)
        val availW = g.displayWidth - 2 * opts.margin
        val availH = g.displayHeight - 2 * opts.margin
        val scale = min(availW / imgW, availH / imgH)
        val drawW = imgW * scale
        val drawH = imgH * scale
        val x = (g.displayWidth - drawW) / 2
        val y = (g.displayHeight - drawH) / 2
        // Draw the stored (un-rotated) image into a box whose size matches the
        // stored orientation, then rotate it upright around the box centre.
        val boxW = if (swap) drawH else drawW
        val boxH = if (swap) drawW else drawH
        var m = g.imageMatrix(x + (drawW - boxW) / 2, y + (drawH - boxH) / 2, boxW, boxH, prepared.rotation.toDouble())
        if (prepared.mirror) {
            // Mirror horizontally around the image centre in display space.
            val cx = x + drawW / 2
            val mirrorT = Affine(-1.0, 0.0, 0.0, 1.0, 2 * cx, 0.0)
            m = inverseDisplay(g, m).then(mirrorT).then(g.displayToUser)
        }
        appendStream(doc, page).use { cs -> cs.drawImage(prepared.image, m.toMatrix()) }
    }

    /** Converts a matrix that ends in user space back to display space (for page rotation 0 pages). */
    private fun inverseDisplay(g: PageGeometry, m: Affine): Affine {
        // New pages created here always have rotation 0: user -> display is y-flip.
        val userToDisplay = Affine(1.0, 0.0, 0.0, -1.0, -g.boxX, g.boxY + g.boxHeight)
        return m.then(userToDisplay)
    }

    private fun prepareImage(
        doc: PDDocument, file: File, bounds: BitmapFactory.Options,
        rotation: Int, mirror: Boolean, opts: ImagePdfOptions,
    ): Prepared {
        val isJpeg = bounds.outMimeType == "image/jpeg"
        if (opts.quality == "original" && isJpeg) {
            // Embed the JPEG stream as-is: no generation loss.
            return Prepared(JPEGFactory.createFromByteArray(doc, file.readBytes()), rotation, mirror)
        }
        val maxSide = when (opts.quality) {
            "medium" -> 1600
            "high" -> 2400
            else -> 4096
        }
        val bitmap = decodeScaled(file, bounds, maxSide)
        try {
            val image = if (opts.quality == "original" && bitmap.hasAlpha()) {
                LosslessFactory.createFromImage(doc, bitmap)
            } else {
                val opaque = flattenOnWhite(bitmap)
                try {
                    JPEGFactory.createFromImage(doc, opaque, if (opts.quality == "medium") 0.75f else 0.88f)
                } finally {
                    if (opaque !== bitmap) opaque.recycle()
                }
            }
            return Prepared(image, rotation, mirror)
        } finally {
            bitmap.recycle()
        }
    }

    fun decodeScaled(file: File, bounds: BitmapFactory.Options, maxSide: Int): Bitmap {
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide ||
            (bounds.outWidth.toLong() / sample) * (bounds.outHeight.toLong() / sample) > MAX_DECODE_PIXELS
        ) sample *= 2
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = try {
            BitmapFactory.decodeFile(file.path, options)
        } catch (e: OutOfMemoryError) {
            throw OpError(OpError.OUT_OF_MEMORY, "Not enough memory to decode ${file.name}.")
        } ?: throw OpError(OpError.INVALID_FILE, "${file.name} could not be decoded.")
        val longest = max(decoded.width, decoded.height)
        if (longest <= maxSide) return decoded
        val s = maxSide.toFloat() / longest
        val scaled = Bitmap.createScaledBitmap(decoded, (decoded.width * s).toInt().coerceAtLeast(1), (decoded.height * s).toInt().coerceAtLeast(1), true)
        if (scaled !== decoded) decoded.recycle()
        return scaled
    }

    fun flattenOnWhite(bitmap: Bitmap): Bitmap {
        if (!bitmap.hasAlpha()) return bitmap
        val out = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        Canvas(out).apply {
            drawColor(Color.WHITE)
            drawBitmap(bitmap, 0f, 0f, null)
        }
        out.setHasAlpha(false)
        return out
    }

    /** Returns (clockwise rotation, mirrored) from EXIF orientation. */
    fun exifRotation(file: File): Pair<Int, Boolean> = try {
        when (ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90 to false
            ExifInterface.ORIENTATION_ROTATE_180 -> 180 to false
            ExifInterface.ORIENTATION_ROTATE_270 -> 270 to false
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> 0 to true
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> 180 to true
            ExifInterface.ORIENTATION_TRANSPOSE -> 90 to true
            ExifInterface.ORIENTATION_TRANSVERSE -> 270 to true
            else -> 0 to false
        }
    } catch (e: Exception) {
        0 to false
    }

    data class TextPdfOptions(
        val fontSize: Float = 11f,
        val margin: Float = 56f,
        val pageSize: String = "a4",
        val lineSpacing: Float = 1.35f,
    )

    fun textToPdf(context: Context, text: String, output: String, opts: TextPdfOptions, ctx: OpContext) {
        if (text.isBlank()) throw OpError.badArgs("There is no text to convert.")
        if (text.length > 5_000_000) throw OpError(OpError.TOO_LARGE, "The text is too long (max 5 million characters).")
        PDDocument().use { doc ->
            val fonts = Fonts(context, doc)
            val font = fonts.forText(text)
            val size = if (opts.pageSize == "letter") PDRectangle.LETTER else PDRectangle.A4
            val maxWidth = size.width - 2 * opts.margin
            val lineHeight = opts.fontSize * opts.lineSpacing
            val linesPerPage = ((size.height - 2 * opts.margin) / lineHeight).toInt().coerceAtLeast(1)

            val lines = ArrayList<String>()
            val paragraphs = text.replace("\r\n", "\n").replace('\t', ' ').split('\n')
            paragraphs.forEachIndexed { i, para ->
                if (i % 200 == 0) ctx.checkCancelled()
                wrap(Fonts.sanitize(font, para), font, opts.fontSize, maxWidth, lines)
            }
            val pageCount = (lines.size + linesPerPage - 1) / linesPerPage
            for (p in 0 until pageCount) {
                ctx.checkCancelled()
                ctx.progress(p, pageCount)
                val page = PDPage(PDRectangle(size.width, size.height))
                doc.addPage(page)
                val g = PdfDocs.geometry(page)
                appendStream(doc, page).use { cs ->
                    cs.setNonStrokingColor(0.1f, 0.1f, 0.12f)
                    val start = p * linesPerPage
                    val end = min(lines.size, start + linesPerPage)
                    for (l in start until end) {
                        val line = lines[l]
                        if (line.isEmpty()) continue
                        val baseline = opts.margin + opts.fontSize + (l - start) * lineHeight
                        drawDisplayText(cs, g, font, line, opts.fontSize, opts.margin.toDouble(), baseline.toDouble())
                    }
                }
            }
            doc.documentInformation.producer = "SnapPDF"
            PdfDocs.save(doc, output)
        }
    }

    /** Greedy word wrap; words longer than a line are broken by character. */
    internal fun wrap(paragraph: String, font: com.tom_roush.pdfbox.pdmodel.font.PDFont, size: Float, maxWidth: Float, out: MutableList<String>) {
        if (paragraph.isEmpty()) {
            out.add("")
            return
        }
        val words = paragraph.split(' ')
        val line = StringBuilder()
        for (word in words) {
            val candidate = if (line.isEmpty()) word else "$line $word"
            if (Fonts.width(font, candidate, size) <= maxWidth) {
                line.clear().append(candidate)
                continue
            }
            if (line.isNotEmpty()) {
                out.add(line.toString())
                line.clear()
            }
            if (Fonts.width(font, word, size) <= maxWidth) {
                line.append(word)
            } else {
                var chunk = StringBuilder()
                for (ch in word) {
                    if (Fonts.width(font, chunk.toString() + ch, size) > maxWidth && chunk.isNotEmpty()) {
                        out.add(chunk.toString())
                        chunk = StringBuilder()
                    }
                    chunk.append(ch)
                }
                line.append(chunk)
            }
        }
        if (line.isNotEmpty()) out.add(line.toString())
    }
}
