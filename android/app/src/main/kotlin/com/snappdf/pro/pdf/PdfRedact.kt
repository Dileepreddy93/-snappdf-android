package com.snappdf.pro.pdf

import android.graphics.Canvas
import android.graphics.Paint
import com.snappdf.pro.OpContext
import com.snappdf.pro.OpError
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocumentInformation
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.File

/**
 * Permanent redaction by re-rasterisation.
 *
 * Every page that contains at least one redaction area is rendered to an
 * image, the areas are painted solid black into the pixels, and the page's
 * content streams, resources and annotations are replaced by that single
 * image. The original text, vector graphics and images of the page are
 * therefore removed from the file, not merely covered.
 *
 * Trade-off: redacted pages are no longer text-searchable. Pages without
 * redactions are left untouched.
 */
object PdfRedact {

    /** [rects] are display-space rectangles in points: left, top, right, bottom. */
    data class PageRedaction(val page: Int, val rects: List<List<Double>>)

    data class Result(val pagesRedacted: Int, val verifiedTextFree: Boolean)

    fun redact(
        input: String, password: String?, output: String, regions: List<PageRedaction>,
        dpi: Float, stripMetadata: Boolean, tempDir: File, ctx: OpContext,
    ): Result {
        val byPage = regions.filter { it.rects.isNotEmpty() }.groupBy { it.page }
            .mapValues { (_, v) -> v.flatMap { it.rects } }
        if (byPage.isEmpty()) throw OpError.badArgs("Mark at least one area to redact.")

        // 1. Rasterise affected pages with the redaction boxes burned in.
        val rendered = HashMap<Int, File>()
        try {
            RasterSession.open(input, password, tempDir).use { session ->
                byPage.keys.sorted().forEachIndexed { i, index ->
                    ctx.checkCancelled()
                    ctx.progress(i, byPage.size * 2, "Rendering page ${index + 1}")
                    if (index !in 0 until session.pageCount) throw OpError.badArgs("Page ${index + 1} does not exist.")
                    val (wPt, hPt) = session.pageSize(index)
                    val bitmap = session.render(index, dpi)
                    try {
                        val sx = bitmap.width / wPt.toFloat()
                        val sy = bitmap.height / hPt.toFloat()
                        val paint = Paint().apply { color = android.graphics.Color.BLACK; style = Paint.Style.FILL }
                        val canvas = Canvas(bitmap)
                        for (r in byPage.getValue(index)) {
                            if (r.size != 4) throw OpError.badArgs("Invalid redaction rectangle.")
                            // Expand by one device pixel to cover anti-aliased glyph edges.
                            canvas.drawRect(
                                (r[0] * sx).toFloat() - 1, (r[1] * sy).toFloat() - 1,
                                (r[2] * sx).toFloat() + 1, (r[3] * sy).toFloat() + 1, paint,
                            )
                        }
                        val file = File.createTempFile("redact", ".jpg", tempDir)
                        PdfRaster.writeBitmap(bitmap, file, "jpg", 90)
                        rendered[index] = file
                    } finally {
                        bitmap.recycle()
                    }
                }
            }

            // 2. Replace the affected pages' content with the flattened image.
            PdfDocs.use(input, password) { doc ->
                PdfDocs.requireModifyPermission(doc)
                // Annotations (including form widgets holding field values) on
                // redacted pages are removed everywhere they are referenced.
                val removedAnnots = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Any, Boolean>())
                byPage.keys.forEach { index ->
                    if (index in 0 until doc.numberOfPages) {
                        doc.getPage(index).annotations.forEach { removedAnnots.add(it.cosObject) }
                    }
                }
                if (removedAnnots.isNotEmpty()) {
                    PdfPages.pruneFieldsByWidgets(doc, removedAnnots)
                    PdfPages.detachReferences(doc.documentCatalog.cosObject, removedAnnots)
                }
                // The structure tree can carry the page's text (ActualText/Alt)
                // and references to its content; drop it.
                doc.documentCatalog.cosObject.removeItem(COSName.STRUCT_TREE_ROOT)
                doc.documentCatalog.cosObject.removeItem(COSName.MARK_INFO)
                byPage.keys.sorted().forEachIndexed { i, index ->
                    ctx.checkCancelled()
                    ctx.progress(byPage.size + i, byPage.size * 2, "Redacting page ${index + 1}")
                    val page = doc.getPage(index)
                    val g = PdfDocs.geometry(page)
                    val w = g.displayWidth.toFloat()
                    val h = g.displayHeight.toFloat()
                    val image = JPEGFactory.createFromByteArray(doc, rendered.getValue(index).readBytes())
                    val dict = page.cosObject
                    dict.removeItem(COSName.ANNOTS)
                    dict.removeItem(COSName.METADATA)
                    dict.removeItem(COSName.PIECE_INFO)
                    dict.removeItem(COSName.getPDFName("Thumb"))
                    dict.removeItem(COSName.getPDFName("B"))
                    dict.removeItem(COSName.STRUCT_PARENTS)
                    dict.removeItem(COSName.GROUP)
                    page.rotation = 0
                    val box = PDRectangle(0f, 0f, w, h)
                    page.mediaBox = box
                    page.cropBox = box
                    dict.removeItem(COSName.BLEED_BOX)
                    dict.removeItem(COSName.TRIM_BOX)
                    dict.removeItem(COSName.ART_BOX)
                    page.resources = PDResources()
                    // OVERWRITE drops every existing content stream.
                    PDPageContentStream(doc, page, PDPageContentStream.AppendMode.OVERWRITE, true).use { cs ->
                        cs.drawImage(image, 0f, 0f, w, h)
                    }
                }
                if (stripMetadata) {
                    doc.documentInformation = PDDocumentInformation().apply { producer = "SnapPDF" }
                    doc.documentCatalog.metadata = null
                }
                PdfDocs.save(doc, output)
            }
        } finally {
            rendered.values.forEach { it.delete() }
        }

        // 3. Verify: redacted pages must contain no extractable text at all.
        val verified = PdfDocs.use(output, null) { doc ->
            val stripper = PDFTextStripper()
            byPage.keys.all { index ->
                stripper.startPage = index + 1
                stripper.endPage = index + 1
                stripper.getText(doc).isBlank()
            }
        }
        if (!verified) {
            File(output).delete()
            throw OpError(OpError.INTERNAL, "Redaction could not be verified, so no file was saved.")
        }
        return Result(byPage.size, verified)
    }
}
