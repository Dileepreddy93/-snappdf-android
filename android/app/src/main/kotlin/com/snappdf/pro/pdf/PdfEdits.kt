package com.snappdf.pro.pdf

import android.content.Context
import com.snappdf.pro.OpContext
import com.snappdf.pro.OpError
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDColor
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDDeviceRGB
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotation
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationMarkup
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationText
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationTextMarkup
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDBorderStyleDictionary
import java.io.File
import java.util.Calendar

/**
 * An edit made in the editor. All coordinates are display-space points of
 * the target page (origin top-left, y down, page rotation applied).
 */
sealed class PdfEdit {
    abstract val page: Int

    data class Text(
        override val page: Int, val x: Double, val y: Double, val text: String,
        val fontSize: Float, val color: Long, val bold: Boolean, val rotation: Double,
    ) : PdfEdit()

    data class Image(
        override val page: Int, val x: Double, val y: Double, val w: Double, val h: Double,
        val path: String, val rotation: Double, val opacity: Float,
    ) : PdfEdit()

    /** Each stroke is a flat list x0, y0, x1, y1, ... */
    data class Ink(
        override val page: Int, val strokes: List<List<Double>>, val color: Long, val width: Float, val opacity: Float,
    ) : PdfEdit()

    /** kind: highlight, underline or strikeout. rect: left, top, right, bottom. */
    data class Markup(override val page: Int, val kind: String, val rect: List<Double>, val color: Long) : PdfEdit()

    data class Note(override val page: Int, val x: Double, val y: Double, val text: String, val color: Long) : PdfEdit()

    data class Stamp(
        override val page: Int, val x: Double, val y: Double, val w: Double, val h: Double,
        val text: String, val color: Long,
    ) : PdfEdit()
}

object PdfEdits {

    fun apply(
        context: Context, input: String, password: String?, output: String,
        edits: List<PdfEdit>, flatten: Boolean, author: String?, ctx: OpContext,
    ) {
        if (edits.isEmpty()) throw OpError.badArgs("There are no changes to save.")
        PdfDocs.use(input, password) { doc ->
            PdfDocs.requireModifyPermission(doc)
            val fonts = Fonts(context, doc)
            val images = HashMap<String, PDImageXObject>()
            val byPage = edits.groupBy { it.page }
            byPage.entries.forEachIndexed { i, (index, pageEdits) ->
                ctx.checkCancelled()
                ctx.progress(i, byPage.size)
                if (index !in 0 until doc.numberOfPages) throw OpError.badArgs("Page ${index + 1} does not exist.")
                val page = doc.getPage(index)
                val g = PdfDocs.geometry(page)
                val annotations = ArrayList<PDAnnotation>()
                appendStream(doc, page).use { cs ->
                    for (edit in pageEdits) {
                        when (edit) {
                            is PdfEdit.Text -> drawText(cs, g, fonts, edit)
                            is PdfEdit.Image -> {
                                val img = images.getOrPut(edit.path) {
                                    val f = File(edit.path)
                                    if (!f.isFile) throw OpError(OpError.IO, "Image not found.")
                                    PDImageXObject.createFromFileByContent(f, doc)
                                }
                                cs.saveGraphicsState()
                                setOpacity(cs, edit.opacity)
                                cs.drawImage(img, g.imageMatrix(edit.x, edit.y, edit.w, edit.h, edit.rotation).toMatrix())
                                cs.restoreGraphicsState()
                            }
                            is PdfEdit.Ink -> if (flatten) drawInk(cs, g, edit) else annotations.add(inkAnnotation(g, edit, author))
                            is PdfEdit.Markup -> if (flatten) drawMarkup(cs, g, edit) else annotations.add(markupAnnotation(g, edit, author))
                            is PdfEdit.Note -> if (flatten) drawNote(cs, g, fonts, edit) else annotations.add(noteAnnotation(g, edit, author))
                            is PdfEdit.Stamp -> drawStamp(cs, g, fonts, edit)
                        }
                    }
                }
                if (annotations.isNotEmpty()) {
                    annotations.forEach { a ->
                        a.page = page
                        a.constructAppearances(doc)
                    }
                    page.annotations = page.annotations + annotations
                }
            }
            ctx.progress(byPage.size, byPage.size)
            PdfDocs.save(doc, output)
        }
    }

    private fun drawText(cs: PDPageContentStream, g: PageGeometry, fonts: Fonts, e: PdfEdit.Text) {
        val font = fonts.forText(e.text, e.bold)
        setRgb(cs, e.color)
        cs.saveGraphicsState()
        setOpacity(cs, alphaOf(e.color).takeIf { it > 0f } ?: 1f)
        val lineHeight = e.fontSize * 1.25
        e.text.split('\n').forEachIndexed { i, raw ->
            val line = Fonts.sanitize(font, raw)
            if (line.isEmpty()) return@forEachIndexed
            val baseline = e.y + e.fontSize * 0.95 + i * lineHeight
            drawDisplayText(cs, g, font, line, e.fontSize, e.x, baseline, e.rotation, e.x, e.y)
        }
        cs.restoreGraphicsState()
    }

    private fun userPoint(g: PageGeometry, x: Double, y: Double): Pair<Float, Float> {
        val (ux, uy) = g.displayToUser.apply(x, y)
        return ux.toFloat() to uy.toFloat()
    }

    private fun userRect(g: PageGeometry, l: Double, t: Double, r: Double, b: Double): PDRectangle {
        val (x1, y1) = userPoint(g, l, t)
        val (x2, y2) = userPoint(g, r, b)
        return PDRectangle(minOf(x1, x2), minOf(y1, y2), kotlin.math.abs(x2 - x1), kotlin.math.abs(y2 - y1))
    }

    private fun color(argb: Long) = PDColor(
        floatArrayOf(((argb shr 16) and 0xFF) / 255f, ((argb shr 8) and 0xFF) / 255f, (argb and 0xFF) / 255f),
        PDDeviceRGB.INSTANCE,
    )

    private fun drawInk(cs: PDPageContentStream, g: PageGeometry, e: PdfEdit.Ink) {
        cs.saveGraphicsState()
        setRgb(cs, e.color, stroke = true)
        setOpacity(cs, e.opacity)
        cs.setLineWidth(e.width)
        cs.setLineCapStyle(1)
        cs.setLineJoinStyle(1)
        for (stroke in e.strokes) {
            if (stroke.size < 2) continue
            val (x0, y0) = userPoint(g, stroke[0], stroke[1])
            cs.moveTo(x0, y0)
            if (stroke.size == 2) {
                cs.lineTo(x0 + 0.01f, y0)
            } else {
                var i = 2
                while (i + 1 < stroke.size) {
                    val (x, y) = userPoint(g, stroke[i], stroke[i + 1])
                    cs.lineTo(x, y)
                    i += 2
                }
            }
            cs.stroke()
        }
        cs.restoreGraphicsState()
    }

    private fun inkAnnotation(g: PageGeometry, e: PdfEdit.Ink, author: String?): PDAnnotation {
        val a = PDAnnotationMarkup()
        a.cosObject.setName(com.tom_roush.pdfbox.cos.COSName.SUBTYPE, PDAnnotationMarkup.SUB_TYPE_INK)
        val paths = e.strokes.filter { it.size >= 2 }.map { stroke ->
            val out = FloatArray(stroke.size)
            var i = 0
            while (i + 1 < stroke.size) {
                val (x, y) = userPoint(g, stroke[i], stroke[i + 1])
                out[i] = x
                out[i + 1] = y
                i += 2
            }
            out
        }
        a.inkList = paths.toTypedArray()
        var minX = Float.MAX_VALUE; var minY = Float.MAX_VALUE; var maxX = -Float.MAX_VALUE; var maxY = -Float.MAX_VALUE
        paths.forEach { p ->
            var i = 0
            while (i + 1 < p.size) {
                minX = minOf(minX, p[i]); maxX = maxOf(maxX, p[i])
                minY = minOf(minY, p[i + 1]); maxY = maxOf(maxY, p[i + 1])
                i += 2
            }
        }
        val pad = e.width
        a.rectangle = PDRectangle(minX - pad, minY - pad, (maxX - minX) + 2 * pad, (maxY - minY) + 2 * pad)
        a.color = color(e.color)
        a.constantOpacity = e.opacity
        a.borderStyle = PDBorderStyleDictionary().apply { width = e.width }
        finish(a, author)
        return a
    }

    private fun markupAnnotation(g: PageGeometry, e: PdfEdit.Markup, author: String?): PDAnnotation {
        val subtype = when (e.kind) {
            "underline" -> PDAnnotationTextMarkup.SUB_TYPE_UNDERLINE
            "strikeout" -> PDAnnotationTextMarkup.SUB_TYPE_STRIKEOUT
            else -> PDAnnotationTextMarkup.SUB_TYPE_HIGHLIGHT
        }
        val (l, t, r, b) = e.rect
        val a = PDAnnotationTextMarkup(subtype)
        // QuadPoints order: upper-left, upper-right, lower-left, lower-right (as displayed).
        val (ulx, uly) = userPoint(g, l, t)
        val (urx, ury) = userPoint(g, r, t)
        val (llx, lly) = userPoint(g, l, b)
        val (lrx, lry) = userPoint(g, r, b)
        a.quadPoints = floatArrayOf(ulx, uly, urx, ury, llx, lly, lrx, lry)
        a.rectangle = userRect(g, l, t, r, b)
        a.color = color(e.color)
        if (subtype == PDAnnotationTextMarkup.SUB_TYPE_HIGHLIGHT) a.constantOpacity = 0.4f
        finish(a, author)
        return a
    }

    private fun drawMarkup(cs: PDPageContentStream, g: PageGeometry, e: PdfEdit.Markup) {
        val (l, t, r, b) = e.rect
        cs.saveGraphicsState()
        when (e.kind) {
            "underline", "strikeout" -> {
                setRgb(cs, e.color, stroke = true)
                val thickness = ((b - t) * 0.08).coerceIn(0.6, 3.0)
                cs.setLineWidth(thickness.toFloat())
                val y = if (e.kind == "underline") b - thickness else (t + b) / 2
                val (x1, y1) = userPoint(g, l, y)
                val (x2, y2) = userPoint(g, r, y)
                cs.moveTo(x1, y1)
                cs.lineTo(x2, y2)
                cs.stroke()
            }
            else -> {
                setRgb(cs, e.color)
                // Multiply keeps the text under the highlight legible.
                val gs = com.tom_roush.pdfbox.pdmodel.graphics.state.PDExtendedGraphicsState().apply {
                    nonStrokingAlphaConstant = 0.4f
                    blendMode = com.tom_roush.pdfbox.pdmodel.graphics.blend.BlendMode.MULTIPLY
                }
                cs.setGraphicsStateParameters(gs)
                val rect = userRect(g, l, t, r, b)
                cs.addRect(rect.lowerLeftX, rect.lowerLeftY, rect.width, rect.height)
                cs.fill()
            }
        }
        cs.restoreGraphicsState()
    }

    private fun noteAnnotation(g: PageGeometry, e: PdfEdit.Note, author: String?): PDAnnotation {
        val a = PDAnnotationText()
        a.contents = e.text
        a.name = PDAnnotationText.NAME_COMMENT
        val (x, y) = userPoint(g, e.x, e.y)
        a.rectangle = PDRectangle(x, y - 20f, 20f, 20f)
        a.color = color(e.color)
        finish(a, author)
        return a
    }

    private fun drawNote(cs: PDPageContentStream, g: PageGeometry, fonts: Fonts, e: PdfEdit.Note) {
        // Flattened note: a small callout box with the comment text.
        val font = fonts.forText(e.text)
        val size = 9f
        val lines = ArrayList<String>()
        e.text.split('\n').forEach { PdfCreate.wrap(Fonts.sanitize(font, it), font, size, 180f, lines) }
        val w = (lines.maxOfOrNull { Fonts.width(font, it, size) } ?: 0f) + 12f
        val h = lines.size * size * 1.3f + 10f
        cs.saveGraphicsState()
        setRgb(cs, 0xFFFFF59DL)
        val rect = userRect(g, e.x, e.y, e.x + w, e.y + h)
        cs.addRect(rect.lowerLeftX, rect.lowerLeftY, rect.width, rect.height)
        cs.fill()
        setRgb(cs, e.color, stroke = true)
        cs.setLineWidth(0.8f)
        cs.addRect(rect.lowerLeftX, rect.lowerLeftY, rect.width, rect.height)
        cs.stroke()
        setRgb(cs, 0xFF202124L)
        lines.forEachIndexed { i, line ->
            if (line.isNotEmpty()) drawDisplayText(cs, g, font, line, size, e.x + 6, e.y + 5 + size + i * size * 1.3)
        }
        cs.restoreGraphicsState()
    }

    private fun drawStamp(cs: PDPageContentStream, g: PageGeometry, fonts: Fonts, e: PdfEdit.Stamp) {
        val font = fonts.latin(bold = true)
        val text = Fonts.sanitize(font, e.text.uppercase())
        cs.saveGraphicsState()
        setRgb(cs, e.color, stroke = true)
        setRgb(cs, e.color)
        setOpacity(cs, 0.9f)
        val border = (e.h * 0.06).coerceIn(1.0, 4.0)
        cs.setLineWidth(border.toFloat())
        val inset = border / 2
        val corners = listOf(
            userPoint(g, e.x + inset, e.y + inset), userPoint(g, e.x + e.w - inset, e.y + inset),
            userPoint(g, e.x + e.w - inset, e.y + e.h - inset), userPoint(g, e.x + inset, e.y + e.h - inset),
        )
        cs.moveTo(corners[0].first, corners[0].second)
        corners.drop(1).forEach { (x, y) -> cs.lineTo(x, y) }
        cs.closePath()
        cs.stroke()
        // Fit the label inside the box.
        var size = (e.h * 0.55).toFloat()
        val maxW = (e.w - 4 * border).toFloat()
        val natural = Fonts.width(font, text, size)
        if (natural > maxW && natural > 0) size *= maxW / natural
        val w = Fonts.width(font, text, size)
        val baseline = e.y + e.h / 2 + size * 0.35
        drawDisplayText(cs, g, font, text, size, e.x + (e.w - w) / 2, baseline)
        cs.restoreGraphicsState()
    }

    private fun finish(a: PDAnnotation, author: String?) {
        a.isPrinted = true
        a.setModifiedDate(Calendar.getInstance())
        if (a is PDAnnotationMarkup) {
            a.creationDate = Calendar.getInstance()
            author?.takeIf { it.isNotBlank() }?.let { a.titlePopup = it }
        }
    }

    /**
     * Burns annotation appearances (except links and popups) and form fields
     * into page content, so they can no longer be edited or hidden.
     */
    fun flattenDocument(input: String, password: String?, output: String, ctx: OpContext): Map<String, Int> {
        var annotationsFlattened = 0
        var fieldsFlattened = 0
        PdfDocs.use(input, password) { doc ->
            PdfDocs.requireModifyPermission(doc)
            doc.documentCatalog.acroForm?.let { form ->
                if (form.hasXFA()) form.xfa = null
                fieldsFlattened = form.fieldTree.count()
                if (fieldsFlattened > 0) {
                    form.refreshAppearances()
                    form.flatten()
                }
            }
            val pages = doc.pages.toList()
            pages.forEachIndexed { i, page ->
                ctx.checkCancelled()
                ctx.progress(i, pages.size)
                annotationsFlattened += flattenAnnotations(doc, page)
            }
            PdfDocs.save(doc, output)
        }
        return mapOf("annotations" to annotationsFlattened, "fields" to fieldsFlattened)
    }

    private fun flattenAnnotations(doc: PDDocument, page: PDPage): Int {
        val annotations = page.annotations
        if (annotations.isEmpty()) return 0
        val keep = ArrayList<PDAnnotation>()
        var count = 0
        appendStream(doc, page).use { cs ->
            for (a in annotations) {
                val subtype = a.subtype
                if (subtype == "Link" || subtype == "Popup" || subtype == "Widget") {
                    if (subtype != "Popup") keep.add(a)
                    continue
                }
                if (a.isHidden || a.isNoView) continue
                var ap = a.normalAppearanceStream
                if (ap == null) {
                    runCatching { a.constructAppearances(doc) }
                    ap = a.normalAppearanceStream
                }
                if (ap == null) {
                    keep.add(a)
                    continue
                }
                val rect = a.rectangle ?: continue
                val bbox = ap.bBox ?: continue
                val m = ap.matrix
                val pts = listOf(
                    m.transformPoint(bbox.lowerLeftX, bbox.lowerLeftY),
                    m.transformPoint(bbox.upperRightX, bbox.lowerLeftY),
                    m.transformPoint(bbox.lowerLeftX, bbox.upperRightY),
                    m.transformPoint(bbox.upperRightX, bbox.upperRightY),
                )
                val minX = pts.minOf { it.x }; val maxX = pts.maxOf { it.x }
                val minY = pts.minOf { it.y }; val maxY = pts.maxOf { it.y }
                if (maxX - minX <= 0f || maxY - minY <= 0f) continue
                val sx = rect.width / (maxX - minX)
                val sy = rect.height / (maxY - minY)
                cs.saveGraphicsState()
                cs.transform(
                    com.tom_roush.pdfbox.util.Matrix(sx, 0f, 0f, sy, rect.lowerLeftX - minX * sx, rect.lowerLeftY - minY * sy),
                )
                cs.drawForm(ap)
                cs.restoreGraphicsState()
                count++
            }
        }
        page.annotations = keep
        return count
    }
}
