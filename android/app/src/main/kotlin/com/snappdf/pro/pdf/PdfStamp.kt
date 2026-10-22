package com.snappdf.pro.pdf

import android.content.Context
import com.snappdf.pro.OpContext
import com.snappdf.pro.OpError
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.pdmodel.graphics.state.PDExtendedGraphicsState
import com.tom_roush.pdfbox.util.Matrix

fun Affine.toMatrix(): Matrix = Matrix(a.toFloat(), b.toFloat(), c.toFloat(), d.toFloat(), e.toFloat(), f.toFloat())

/** Opens an append-mode content stream with a clean graphics state. */
fun appendStream(doc: PDDocument, page: PDPage): PDPageContentStream =
    PDPageContentStream(doc, page, PDPageContentStream.AppendMode.APPEND, true, true)

fun setRgb(cs: PDPageContentStream, argb: Long, stroke: Boolean = false) {
    val r = ((argb shr 16) and 0xFF) / 255f
    val g = ((argb shr 8) and 0xFF) / 255f
    val b = (argb and 0xFF) / 255f
    if (stroke) cs.setStrokingColor(r, g, b) else cs.setNonStrokingColor(r, g, b)
}

fun alphaOf(argb: Long): Float = ((argb shr 24) and 0xFF) / 255f

fun setOpacity(cs: PDPageContentStream, fill: Float, stroke: Float = fill) {
    if (fill >= 0.999f && stroke >= 0.999f) return
    val gs = PDExtendedGraphicsState().apply {
        nonStrokingAlphaConstant = fill.coerceIn(0f, 1f)
        strokingAlphaConstant = stroke.coerceIn(0f, 1f)
    }
    cs.setGraphicsStateParameters(gs)
}

/** Draws a single line of [text] upright in display space. */
fun drawDisplayText(
    cs: PDPageContentStream,
    g: PageGeometry,
    font: PDFont,
    text: String,
    size: Float,
    x: Double,
    baselineY: Double,
    rotationDegrees: Double = 0.0,
    pivotX: Double = x,
    pivotY: Double = baselineY,
) {
    cs.beginText()
    cs.setFont(font, size)
    cs.setTextMatrix(g.textMatrix(x, baselineY, rotationDegrees, pivotX, pivotY).toMatrix())
    cs.showText(text)
    cs.endText()
}

object PdfStamp {

    data class Watermark(
        val text: String?,
        val imagePath: String?,
        val fontSize: Float,
        val color: Long,
        val opacity: Float,
        val rotation: Double,
        /** "center" or "tile". */
        val layout: String,
        /** Image width as a fraction of the page width. */
        val imageScale: Double,
        val pages: List<Int>?,
    )

    fun watermark(context: Context, input: String, password: String?, output: String, wm: Watermark, ctx: OpContext) {
        if (wm.text.isNullOrBlank() && wm.imagePath == null) throw OpError.badArgs("Enter watermark text or choose an image.")
        PdfDocs.use(input, password) { doc ->
            val fonts = Fonts(context, doc)
            val font = wm.text?.let { fonts.forText(it, bold = true) }
            val text = if (font != null && wm.text != null) Fonts.sanitize(font, wm.text) else null
            val image = wm.imagePath?.let { PDImageXObject.createFromFileByContent(java.io.File(it), doc) }
            val indices = PdfDocs.pageIndices(wm.pages, doc.numberOfPages)
            indices.forEachIndexed { i, index ->
                ctx.checkCancelled()
                ctx.progress(i, indices.size)
                val page = doc.getPage(index)
                val g = PdfDocs.geometry(page)
                appendStream(doc, page).use { cs ->
                    setOpacity(cs, wm.opacity)
                    val positions = if (wm.layout == "tile") tilePositions(g) else listOf(g.displayWidth / 2 to g.displayHeight / 2)
                    for ((cx, cy) in positions) {
                        if (font != null && text != null) {
                            setRgb(cs, wm.color)
                            val w = Fonts.width(font, text, wm.fontSize)
                            val baseline = cy + wm.fontSize * 0.35
                            drawDisplayText(cs, g, font, text, wm.fontSize, cx - w / 2, baseline, wm.rotation, cx, cy)
                        }
                        if (image != null) {
                            val w = g.displayWidth * wm.imageScale.coerceIn(0.05, 1.0)
                            val h = w * image.height / image.width
                            cs.drawImage(image, g.imageMatrix(cx - w / 2, cy - h / 2, w, h, wm.rotation).toMatrix())
                        }
                    }
                }
            }
            PdfDocs.save(doc, output)
        }
    }

    private fun tilePositions(g: PageGeometry): List<Pair<Double, Double>> {
        val out = ArrayList<Pair<Double, Double>>()
        val stepX = g.displayWidth / 2.0
        val stepY = g.displayHeight / 3.0
        for (row in 0 until 3) for (col in 0 until 2) {
            val offset = if (row % 2 == 0) 0.0 else stepX / 2
            out.add((stepX / 2 + col * stepX + offset - stepX / 4) to (stepY / 2 + row * stepY))
        }
        return out
    }

    data class PageNumbers(
        /** Format with {n} (page number) and {total}. Empty disables numbering. */
        val format: String,
        /** One of top-left, top-center, top-right, bottom-left, bottom-center, bottom-right. */
        val position: String,
        val fontSize: Float,
        val color: Long,
        val margin: Double,
        val startAt: Int,
        val skipFirst: Boolean,
        val header: String?,
        val footer: String?,
        val pages: List<Int>?,
    )

    fun pageNumbers(context: Context, input: String, password: String?, output: String, opts: PageNumbers, ctx: OpContext) {
        if (opts.format.isBlank() && opts.header.isNullOrBlank() && opts.footer.isNullOrBlank()) {
            throw OpError.badArgs("Nothing to add: enter a page-number format, header or footer.")
        }
        PdfDocs.use(input, password) { doc ->
            val fonts = Fonts(context, doc)
            val indices = PdfDocs.pageIndices(opts.pages, doc.numberOfPages).filter { !(opts.skipFirst && it == 0) }
            val total = indices.size
            indices.forEachIndexed { i, index ->
                ctx.checkCancelled()
                ctx.progress(i, total)
                val page = doc.getPage(index)
                val g = PdfDocs.geometry(page)
                appendStream(doc, page).use { cs ->
                    setRgb(cs, opts.color)
                    if (opts.format.isNotBlank()) {
                        val label = opts.format
                            .replace("{n}", (opts.startAt + i).toString())
                            .replace("{total}", (opts.startAt + total - 1).toString())
                        placeText(cs, g, fonts, label, opts.position, opts.fontSize, opts.margin)
                    }
                    opts.header?.takeIf { it.isNotBlank() }?.let {
                        placeText(cs, g, fonts, it, "top-center", opts.fontSize, opts.margin)
                    }
                    opts.footer?.takeIf { it.isNotBlank() }?.let {
                        val pos = if (opts.position == "bottom-center" && opts.format.isNotBlank()) "bottom-left" else "bottom-center"
                        placeText(cs, g, fonts, it, pos, opts.fontSize, opts.margin)
                    }
                }
            }
            PdfDocs.save(doc, output)
        }
    }

    private fun placeText(
        cs: PDPageContentStream, g: PageGeometry, fonts: Fonts, raw: String,
        position: String, size: Float, margin: Double,
    ) {
        val font = fonts.forText(raw)
        val text = Fonts.sanitize(font, raw)
        val w = Fonts.width(font, text, size)
        val x = when {
            position.endsWith("left") -> margin
            position.endsWith("right") -> g.displayWidth - margin - w
            else -> (g.displayWidth - w) / 2
        }
        val baseline = if (position.startsWith("top")) margin + size else g.displayHeight - margin
        drawDisplayText(cs, g, font, text, size, x, baseline)
    }
}
