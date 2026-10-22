package com.snappdf.pro

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.test.platform.app.InstrumentationRegistry
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.cos.COSStream
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.graphics.image.LosslessFactory
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.snappdf.pro.pdf.PdfDocs
import java.io.File
import java.io.FileOutputStream

/** Builds realistic PDF/image fixtures on the device for engine tests. */
object Fixtures {
    val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    val dir: File by lazy {
        PDFBoxResourceLoader.init(context)
        PdfDocs.tempDir = File(context.cacheDir, "pdfbox-test")
        File(context.cacheDir, "engine-tests").apply { deleteRecursively(); mkdirs() }
    }

    fun file(name: String) = File(dir, name)

    /** A text PDF: page i contains "PAGE-<i+1> <marker>" in Helvetica. */
    fun textPdf(name: String, pages: Int, marker: String = "", rotations: List<Int> = emptyList(), size: PDRectangle = PDRectangle.A4): File {
        val out = file(name)
        PDDocument().use { doc ->
            for (i in 0 until pages) {
                val page = PDPage(size)
                rotations.getOrNull(i)?.let { page.rotation = it }
                doc.addPage(page)
                PDPageContentStream(doc, page).use { cs ->
                    cs.beginText()
                    cs.setFont(PDType1Font.HELVETICA, 18f)
                    cs.newLineAtOffset(72f, size.height - 100f)
                    cs.showText("PAGE-${i + 1} $marker".trim())
                    cs.endText()
                }
            }
            doc.save(out)
        }
        return out
    }

    fun textOf(path: String, page: Int? = null, password: String? = null): String = PdfDocs.use(path, password) { doc ->
        val stripper = PDFTextStripper()
        if (page != null) {
            stripper.startPage = page + 1
            stripper.endPage = page + 1
        }
        stripper.getText(doc)
    }

    /**
     * Text with all whitespace removed. PDFBox emits one character per line
     * for text that runs at an angle to the displayed page (rotated pages,
     * diagonal watermarks), so content checks for such text compare compactly.
     */
    fun compactTextOf(path: String, page: Int? = null): String = textOf(path, page).replace(Regex("\\s+"), "")

    fun pageCount(path: String, password: String? = null) = PdfDocs.use(path, password) { it.numberOfPages }

    /**
     * True if [marker] occurs anywhere in the raw file or inside any
     * Flate-compressed stream. Scans bytes directly, independent of PDFBox's
     * object model, so unreachable leftovers are detected too.
     */
    fun anyStreamContains(path: String, marker: String): Boolean {
        val bytes = File(path).readBytes()
        val text = String(bytes, Charsets.ISO_8859_1)
        if (text.contains(marker)) return true
        var from = 0
        while (true) {
            val start = text.indexOf("stream", from).takeIf { it >= 0 } ?: return false
            var dataStart = start + "stream".length
            if (dataStart < bytes.size && bytes[dataStart] == '\r'.code.toByte()) dataStart++
            if (dataStart < bytes.size && bytes[dataStart] == '\n'.code.toByte()) dataStart++
            val end = text.indexOf("endstream", dataStart).takeIf { it >= 0 } ?: return false
            val inflater = java.util.zip.Inflater()
            try {
                inflater.setInput(bytes, dataStart, end - dataStart)
                val out = java.io.ByteArrayOutputStream()
                val buf = ByteArray(8192)
                while (!inflater.finished()) {
                    val n = inflater.inflate(buf)
                    if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) break
                    out.write(buf, 0, n)
                }
                if (String(out.toByteArray(), Charsets.ISO_8859_1).contains(marker)) return true
            } catch (e: java.util.zip.DataFormatException) {
                // Not a Flate stream (e.g. JPEG); ignore.
            } finally {
                inflater.end()
            }
            from = end + "endstream".length
        }
    }

    /** Noisy image that compresses poorly with lossless encoding. */
    fun noisyBitmap(w: Int, h: Int): Bitmap {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val rnd = java.util.Random(42)
        val pixels = IntArray(w * h) { i ->
            val x = i % w
            val y = i / w
            val r = (x * 255 / w + rnd.nextInt(40)).coerceIn(0, 255)
            val g = (y * 255 / h + rnd.nextInt(40)).coerceIn(0, 255)
            Color.rgb(r, g, rnd.nextInt(256))
        }
        bmp.setPixels(pixels, 0, w, 0, 0, w, h)
        return bmp
    }

    fun imageHeavyPdf(name: String, pages: Int = 2): File {
        val out = file(name)
        PDDocument().use { doc ->
            val bmp = noisyBitmap(2400, 3200)
            val image = LosslessFactory.createFromImage(doc, bmp)
            bmp.recycle()
            repeat(pages) {
                val page = PDPage(PDRectangle.A4)
                doc.addPage(page)
                PDPageContentStream(doc, page).use { cs ->
                    cs.drawImage(image, 0f, 0f, PDRectangle.A4.width, PDRectangle.A4.height)
                    cs.beginText()
                    cs.setFont(PDType1Font.HELVETICA_BOLD, 24f)
                    cs.newLineAtOffset(60f, 60f)
                    cs.showText("SCANNED PAGE ${it + 1}")
                    cs.endText()
                }
            }
            doc.save(out)
        }
        return out
    }

    fun writeBitmap(bitmap: Bitmap, name: String, format: Bitmap.CompressFormat = Bitmap.CompressFormat.PNG, quality: Int = 100): File {
        val out = file(name)
        FileOutputStream(out).use { bitmap.compress(format, quality, it) }
        return out
    }

    fun solid(w: Int, h: Int, color: Int): Bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { eraseColor(color) }

    /** Left half red, right half blue. */
    fun splitBitmap(w: Int, h: Int): Bitmap {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.drawRect(0f, 0f, w / 2f, h.toFloat(), Paint().apply { color = Color.RED })
        c.drawRect(w / 2f, 0f, w.toFloat(), h.toFloat(), Paint().apply { color = Color.BLUE })
        return bmp
    }

    fun textBitmap(lines: List<String>, w: Int = 1600, h: Int = 900): Bitmap {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.drawColor(Color.WHITE)
        val p = Paint().apply {
            color = Color.BLACK
            textSize = 72f
            isAntiAlias = true
            typeface = android.graphics.Typeface.DEFAULT_BOLD
        }
        lines.forEachIndexed { i, line -> c.drawText(line, 80f, 160f + i * 140f, p) }
        return bmp
    }

    fun isDark(color: Int) = Color.red(color) < 60 && Color.green(color) < 60 && Color.blue(color) < 60
    fun isWhite(color: Int) = Color.red(color) > 220 && Color.green(color) > 220 && Color.blue(color) > 220
    fun isRed(color: Int) = Color.red(color) > 180 && Color.green(color) < 80 && Color.blue(color) < 80
    fun isBlue(color: Int) = Color.blue(color) > 180 && Color.red(color) < 80 && Color.green(color) < 80
}

class RecordingContext(private val cancelAfter: Int = Int.MAX_VALUE) : OpContext {
    var checks = 0
    val events = ArrayList<Pair<Int, Int>>()
    override fun checkCancelled() {
        checks++
        if (checks > cancelAfter) throw OpError(OpError.CANCELLED, "Cancelled.")
    }

    override fun progress(done: Int, total: Int, message: String?) {
        events.add(done to total)
    }
}
