package com.snappdf.pro.ml

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.snappdf.pro.OpContext
import com.snappdf.pro.OpError
import com.snappdf.pro.pdf.Fonts
import com.snappdf.pro.pdf.PageGeometry
import com.snappdf.pro.pdf.PdfCreate
import com.snappdf.pro.pdf.PdfDocs
import com.snappdf.pro.pdf.RasterSession
import com.snappdf.pro.pdf.appendStream
import com.snappdf.pro.pdf.toMatrix
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.state.RenderingMode
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.File
import java.util.concurrent.ExecutionException

/**
 * On-device text recognition (ML Kit, bundled models).
 * Supported scripts: Latin ("latin") and Devanagari incl. Latin ("devanagari").
 * Telugu is not supported by ML Kit and is rejected explicitly.
 */
object Ocr {
    private val recognizers = HashMap<String, TextRecognizer>()

    @Synchronized
    private fun recognizer(script: String): TextRecognizer = recognizers.getOrPut(script) {
        when (script) {
            "latin" -> TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            "devanagari" -> TextRecognition.getClient(DevanagariTextRecognizerOptions.Builder().build())
            else -> throw OpError(OpError.UNSUPPORTED, "Text recognition for \"$script\" is not available on this device.")
        }
    }

    fun recognize(bitmap: Bitmap, script: String): Text = try {
        Tasks.await(recognizer(script).process(InputImage.fromBitmap(bitmap, 0)))
    } catch (e: ExecutionException) {
        throw OpError(OpError.UNAVAILABLE, "Text recognition failed: ${e.cause?.message ?: e.message}", e)
    }

    /** Decodes an image upright (EXIF applied), limited to [maxSide] pixels. */
    fun decodeUpright(path: String, maxSide: Int = 4000): Bitmap {
        val file = File(path)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0) throw OpError(OpError.INVALID_FILE, "${file.name} is not a supported image.")
        val bitmap = PdfCreate.decodeScaled(file, bounds, maxSide)
        val (rotation, mirror) = PdfCreate.exifRotation(file)
        if (rotation == 0 && !mirror) return bitmap
        val m = Matrix().apply {
            postRotate(rotation.toFloat())
            if (mirror) postScale(-1f, 1f)
        }
        val out = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
        if (out !== bitmap) bitmap.recycle()
        return out
    }

    fun recognizeFile(path: String, script: String): Map<String, Any?> {
        val bitmap = decodeUpright(path)
        try {
            val text = recognize(bitmap, script)
            return mapOf(
                "text" to text.text,
                "width" to bitmap.width,
                "height" to bitmap.height,
                "blocks" to text.textBlocks.map { block ->
                    mapOf(
                        "text" to block.text,
                        "lines" to block.lines.map { line ->
                            val b = line.boundingBox
                            mapOf(
                                "text" to line.text,
                                "box" to if (b != null) listOf(b.left, b.top, b.right, b.bottom) else null,
                                "confidence" to line.confidence.toDouble(),
                            )
                        },
                    )
                },
            )
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * Writes recognised lines as invisible text. [scale] converts bitmap
     * pixels to display points; ([offsetX], [offsetY]) is where the bitmap's
     * top-left lies in display space.
     */
    private fun writeTextLayer(
        cs: PDPageContentStream, g: PageGeometry, fonts: Fonts, text: Text,
        scale: Double, offsetX: Double, offsetY: Double,
    ): Int {
        var lines = 0
        cs.beginText()
        cs.setRenderingMode(RenderingMode.NEITHER)
        for (block in text.textBlocks) for (line in block.lines) {
            val box = line.boundingBox ?: continue
            val raw = line.text.trim()
            if (raw.isEmpty() || box.width() <= 0 || box.height() <= 0) continue
            val font = fonts.forText(raw)
            val content = Fonts.sanitize(font, raw)
            val h = box.height() * scale
            val w = box.width() * scale
            val size = (h / 1.15).toFloat().coerceAtLeast(1f)
            val natural = Fonts.width(font, content, size)
            if (natural <= 0f) continue
            cs.setFont(font, size)
            cs.setHorizontalScaling((w / natural * 100).toFloat().coerceIn(10f, 1000f))
            val x = offsetX + box.left * scale
            val baseline = offsetY + box.bottom * scale - size * 0.2
            cs.setTextMatrix(g.textMatrix(x, baseline).toMatrix())
            cs.showText(content)
            lines++
        }
        cs.endText()
        return lines
    }

    data class SearchableResult(val pages: Int, val linesRecognized: Int, val text: String)

    /** Builds a searchable PDF from images: each image becomes an A4/fit page with a hidden text layer. */
    fun imagesToSearchablePdf(
        context: Context, images: List<String>, output: String, script: String, pageSize: String, ctx: OpContext,
    ): SearchableResult {
        if (images.isEmpty()) throw OpError.badArgs("Select at least one image.")
        var lineCount = 0
        val allText = StringBuilder()
        PDDocument().use { doc ->
            val fonts = Fonts(context, doc)
            images.forEachIndexed { i, path ->
                ctx.checkCancelled()
                ctx.progress(i, images.size, "Recognising page ${i + 1}")
                val bitmap = decodeUpright(path, 3500)
                try {
                    val text = recognize(bitmap, script)
                    allText.append(text.text).append("\n\n")
                    val landscape = bitmap.width > bitmap.height
                    val box = when (pageSize) {
                        "fit" -> {
                            val w = if (landscape) 842f else 595f
                            PDRectangle(w, w * bitmap.height / bitmap.width)
                        }
                        else -> if (landscape) PDRectangle(PDRectangle.A4.height, PDRectangle.A4.width) else PDRectangle.A4
                    }
                    val page = PDPage(box)
                    doc.addPage(page)
                    val g = PdfDocs.geometry(page)
                    val scale = minOf(g.displayWidth / bitmap.width, g.displayHeight / bitmap.height)
                    val drawW = bitmap.width * scale
                    val drawH = bitmap.height * scale
                    val ox = (g.displayWidth - drawW) / 2
                    val oy = (g.displayHeight - drawH) / 2
                    val opaque = PdfCreate.flattenOnWhite(bitmap)
                    val image = try {
                        JPEGFactory.createFromImage(doc, opaque, 0.85f)
                    } finally {
                        if (opaque !== bitmap) opaque.recycle()
                    }
                    appendStream(doc, page).use { cs ->
                        cs.drawImage(image, g.imageMatrix(ox, oy, drawW, drawH).toMatrix())
                        lineCount += writeTextLayer(cs, g, fonts, text, scale, ox, oy)
                    }
                } finally {
                    bitmap.recycle()
                }
            }
            ctx.progress(images.size, images.size)
            doc.documentInformation.producer = "SnapPDF"
            PdfDocs.save(doc, output)
        }
        return SearchableResult(images.size, lineCount, allText.toString().trim())
    }

    /**
     * Adds a hidden text layer to pages of an existing PDF. Pages that already
     * contain text are skipped unless [force] is set. Original page content is
     * not modified.
     */
    fun ocrPdf(
        context: Context, input: String, password: String?, output: String, script: String,
        force: Boolean, tempDir: File, ctx: OpContext,
    ): SearchableResult {
        var lineCount = 0
        var processed = 0
        val allText = StringBuilder()
        val recognized = HashMap<Int, Pair<Text, Pair<Int, Int>>>()
        // Pass 1: decide which pages need OCR and recognise them.
        val needsOcr = PdfDocs.use(input, password) { doc ->
            PdfDocs.requireModifyPermission(doc)
            val stripper = PDFTextStripper()
            (0 until doc.numberOfPages).filter { index ->
                if (force) return@filter true
                stripper.startPage = index + 1
                stripper.endPage = index + 1
                stripper.getText(doc).trim().length < 8
            }
        }
        if (needsOcr.isEmpty()) {
            throw OpError(OpError.UNSUPPORTED, "Every page already contains selectable text.")
        }
        RasterSession.open(input, password, tempDir).use { session ->
            needsOcr.forEachIndexed { i, index ->
                ctx.checkCancelled()
                ctx.progress(i, needsOcr.size + 1, "Recognising page ${index + 1}")
                val bitmap = session.render(index, 300f, 16_000_000L)
                try {
                    recognized[index] = recognize(bitmap, script) to (bitmap.width to bitmap.height)
                } finally {
                    bitmap.recycle()
                }
            }
        }
        // Pass 2: write invisible text over the original pages.
        PdfDocs.use(input, password) { doc ->
            val fonts = Fonts(context, doc)
            for (index in needsOcr) {
                val (text, size) = recognized[index] ?: continue
                val page = doc.getPage(index)
                val g = PdfDocs.geometry(page)
                val scale = g.displayWidth / size.first
                appendStream(doc, page).use { cs ->
                    lineCount += writeTextLayer(cs, g, fonts, text, scale, 0.0, 0.0)
                }
                allText.append(text.text).append("\n\n")
                processed++
            }
            ctx.progress(needsOcr.size + 1, needsOcr.size + 1)
            PdfDocs.save(doc, output)
        }
        return SearchableResult(processed, lineCount, allText.toString().trim())
    }
}
