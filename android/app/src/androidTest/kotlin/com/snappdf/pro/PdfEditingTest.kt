package com.snappdf.pro

import android.graphics.Bitmap
import android.graphics.Color
import androidx.exifinterface.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.snappdf.pro.Fixtures.file
import com.snappdf.pro.Fixtures.textOf
import com.snappdf.pro.Fixtures.textPdf
import com.snappdf.pro.io.SecureStore
import com.snappdf.pro.ml.Ocr
import com.snappdf.pro.pdf.PdfCreate
import com.snappdf.pro.pdf.PdfDocs
import com.snappdf.pro.pdf.PdfEdit
import com.snappdf.pro.pdf.PdfEdits
import com.snappdf.pro.pdf.PdfForms
import com.snappdf.pro.pdf.PdfRaster
import com.snappdf.pro.pdf.PdfRedact
import com.snappdf.pro.pdf.RasterSession
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDAcroForm
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDCheckBox
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDTextField
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class PdfEditingTest {

    private val tempDir get() = File(Fixtures.dir, "tmp").apply { mkdirs() }

    private fun render(path: String, page: Int, dpi: Float = 72f): Bitmap =
        RasterSession.open(path, null, tempDir).use { it.render(page, dpi) }

    /** Pixel at a display-space point (points) on a page rendered at 72 dpi. */
    private fun pixel(bmp: Bitmap, x: Double, y: Double) = bmp.getPixel(x.toInt(), y.toInt())

    @Test
    fun signatureImageLandsAtDisplayPositionOnEveryRotation() {
        val ink = Fixtures.writeBitmap(Fixtures.solid(200, 100, Color.BLACK), "sig.png")
        for (rotation in listOf(0, 90, 180, 270)) {
            val src = textPdf("sig_src_$rotation.pdf", 1, rotations = listOf(rotation))
            val out = file("sig_out_$rotation.pdf")
            // Place in the display top-left quadrant.
            PdfEdits.apply(
                Fixtures.context, src.path, null, out.path,
                listOf(PdfEdit.Image(0, 40.0, 60.0, 200.0, 100.0, ink.path, 0.0, 1f)),
                flatten = true, author = null, ctx = OpContext.NONE,
            )
            val bmp = render(out.path, 0)
            try {
                assertTrue("rotation $rotation inside", Fixtures.isDark(pixel(bmp, 140.0, 110.0)))
                assertTrue("rotation $rotation left of image", Fixtures.isWhite(pixel(bmp, 20.0, 110.0)))
                assertTrue("rotation $rotation below image", Fixtures.isWhite(pixel(bmp, 140.0, 190.0)))
                assertTrue("rotation $rotation far corner", Fixtures.isWhite(pixel(bmp, bmp.width - 20.0, bmp.height - 20.0)))
            } finally {
                bmp.recycle()
            }
        }
    }

    @Test
    fun rotatedSignatureStaysCentred() {
        val ink = Fixtures.writeBitmap(Fixtures.solid(200, 40, Color.BLACK), "bar.png")
        val src = textPdf("rot_sig.pdf", 1)
        val out = file("rot_sig_out.pdf")
        // A 200x40 bar rotated 90 degrees becomes a vertical 40x200 bar around (300, 300).
        PdfEdits.apply(
            Fixtures.context, src.path, null, out.path,
            listOf(PdfEdit.Image(0, 200.0, 280.0, 200.0, 40.0, ink.path, 90.0, 1f)), true, null, OpContext.NONE,
        )
        val bmp = render(out.path, 0)
        try {
            assertTrue(Fixtures.isDark(pixel(bmp, 300.0, 220.0)))
            assertTrue(Fixtures.isDark(pixel(bmp, 300.0, 380.0)))
            assertTrue(Fixtures.isWhite(pixel(bmp, 220.0, 300.0)))
        } finally {
            bmp.recycle()
        }
    }

    @Test
    fun redactionRemovesTextAndPaintsBoxesOnEveryRotation() {
        for (rotation in listOf(0, 90, 180, 270)) {
            val src = textPdf("red_src_$rotation.pdf", 2, "ACCOUNT-998877", rotations = listOf(rotation, 0))
            val out = file("red_out_$rotation.pdf")
            val result = PdfRedact.redact(
                src.path, null, out.path,
                listOf(PdfRedact.PageRedaction(0, listOf(listOf(50.0, 50.0, 250.0, 150.0)))),
                150f, true, tempDir, OpContext.NONE,
            )
            assertEquals(1, result.pagesRedacted)
            assertTrue(result.verifiedTextFree)
            assertTrue("page 1 text removed", textOf(out.path, 0).isBlank())
            assertTrue("page 2 untouched", textOf(out.path, 1).contains("PAGE-2 ACCOUNT-998877"))
            assertFalse(Fixtures.anyStreamContains(out.path, "PAGE-1"))
            val bmp = render(out.path, 0)
            try {
                assertTrue("box painted ($rotation)", Fixtures.isDark(pixel(bmp, 150.0, 100.0)))
                assertTrue("outside box white ($rotation)", Fixtures.isWhite(pixel(bmp, 300.0, 300.0)))
            } finally {
                bmp.recycle()
            }
        }
    }

    @Test
    fun redactionRemovesFormValuesOnRedactedPage() {
        val src = formPdf("red_form.pdf")
        val filled = file("red_form_filled.pdf")
        PdfForms.fill(src.path, null, filled.path, mapOf("fullName" to "PRIVATE-NAME-42"), flatten = false)
        assertTrue(Fixtures.anyStreamContains(filled.path, "PRIVATE-NAME-42") ||
            File(filled.path).readText(Charsets.ISO_8859_1).contains("PRIVATE-NAME-42"))
        val out = file("red_form_out.pdf")
        PdfRedact.redact(filled.path, null, out.path, listOf(PdfRedact.PageRedaction(0, listOf(listOf(0.0, 0.0, 10.0, 10.0)))), 100f, true, tempDir, OpContext.NONE)
        assertFalse(Fixtures.anyStreamContains(out.path, "PRIVATE-NAME-42"))
    }

    @Test
    fun textEditsAndAnnotations() {
        val src = textPdf("edit_src.pdf", 1, rotations = listOf(90))
        val out = file("edit_out.pdf")
        PdfEdits.apply(
            Fixtures.context, src.path, null, out.path,
            listOf(
                PdfEdit.Text(0, 60.0, 200.0, "Hello Edit\nSecond line", 16f, 0xFF0000FF, false, 0.0),
                PdfEdit.Markup(0, "highlight", listOf(60.0, 60.0, 260.0, 90.0), 0xFFFFEB3B),
                PdfEdit.Markup(0, "strikeout", listOf(60.0, 100.0, 260.0, 120.0), 0xFFFF0000),
                PdfEdit.Note(0, 300.0, 300.0, "Check this", 0xFFF9A825),
                PdfEdit.Ink(0, listOf(listOf(100.0, 400.0, 150.0, 420.0, 200.0, 400.0)), 0xFF000000, 2f, 1f),
                PdfEdit.Stamp(0, 100.0, 500.0, 200.0, 60.0, "Approved", 0xFF2E7D32),
            ),
            flatten = false, author = "Tester", ctx = OpContext.NONE,
        )
        val text = textOf(out.path, 0)
        assertTrue(text.contains("Hello Edit"))
        assertTrue(text.contains("Second line"))
        assertTrue(text.contains("APPROVED"))
        PdfDocs.use(out.path, null) { doc ->
            val annots = doc.getPage(0).annotations
            assertEquals(listOf("Highlight", "StrikeOut", "Text", "Ink"), annots.map { it.subtype })
            annots.forEach { assertTrue("${it.subtype} has appearance", it.normalAppearanceStream != null) }
        }
        // Flattening burns them in and removes the annotation objects.
        val flat = file("edit_flat.pdf")
        val counts = PdfEdits.flattenDocument(out.path, null, flat.path, OpContext.NONE)
        assertEquals(4, counts["annotations"])
        PdfDocs.use(flat.path, null) { assertTrue(it.getPage(0).annotations.isEmpty()) }
        assertTrue(textOf(flat.path, 0).contains("Hello Edit"))
    }

    private fun formPdf(name: String): File {
        val out = file(name)
        PDDocument().use { doc ->
            val page = PDPage(PDRectangle.A4)
            doc.addPage(page)
            val form = PDAcroForm(doc)
            doc.documentCatalog.acroForm = form
            val res = PDResources()
            res.put(com.tom_roush.pdfbox.cos.COSName.getPDFName("Helv"), PDType1Font.HELVETICA)
            form.defaultResources = res
            form.defaultAppearance = "/Helv 12 Tf 0 g"
            val text = PDTextField(form).apply { partialName = "fullName" }
            val tw = text.widgets[0]
            tw.rectangle = PDRectangle(72f, 700f, 300f, 24f)
            tw.page = page
            page.annotations.add(tw)
            form.fields.add(text)
            val box = PDCheckBox(form).apply { partialName = "agree" }
            val bw: PDAnnotationWidget = box.widgets[0]
            bw.rectangle = PDRectangle(72f, 650f, 16f, 16f)
            bw.page = page
            page.annotations.add(bw)
            form.fields.add(box)
            doc.save(out)
        }
        return out
    }

    @Test
    fun formFieldsAreListedFilledAndFlattened() {
        val src = formPdf("form.pdf")
        @Suppress("UNCHECKED_CAST")
        val fields = PdfForms.listFields(src.path, null)["fields"] as List<Map<String, Any?>>
        assertEquals(listOf("fullName", "agree"), fields.map { it["name"] })
        assertEquals("text", fields[0]["type"])
        assertEquals(0, fields[0]["page"])
        val filled = file("form_filled.pdf")
        PdfForms.fill(src.path, null, filled.path, mapOf("fullName" to "Ravi Kumar"), flatten = false)
        PdfDocs.use(filled.path, null) { doc ->
            assertEquals("Ravi Kumar", doc.documentCatalog.acroForm.getField("fullName").valueAsString)
        }
        val flat = file("form_flat.pdf")
        PdfForms.fill(src.path, null, flat.path, mapOf("fullName" to "Ravi Kumar"), flatten = true)
        PdfDocs.use(flat.path, null) { doc ->
            assertTrue(doc.documentCatalog.acroForm == null || doc.documentCatalog.acroForm.fields.isEmpty())
        }
        assertTrue(textOf(flat.path).contains("Ravi Kumar"))
    }

    @Test
    fun imagesToPdfAppliesExifOrientation() {
        // Stored landscape 400x200: left red, right blue; EXIF says rotate 90 CW.
        val img = Fixtures.writeBitmap(Fixtures.splitBitmap(400, 200), "exif.jpg", Bitmap.CompressFormat.JPEG, 95)
        ExifInterface(img.path).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            saveAttributes()
        }
        val out = file("exif.pdf")
        PdfCreate.imagesToPdf(listOf(img.path), out.path, PdfCreate.ImagePdfOptions(pageSize = "fit"), OpContext.NONE)
        PdfDocs.use(out.path, null) { doc ->
            val box = doc.getPage(0).mediaBox
            assertTrue("portrait page", box.height > box.width)
        }
        val bmp = render(out.path, 0)
        try {
            // After a 90 CW rotation the left (red) half is on top.
            assertTrue(Fixtures.isRed(bmp.getPixel(bmp.width / 2, bmp.height / 4)))
            assertTrue(Fixtures.isBlue(bmp.getPixel(bmp.width / 2, bmp.height * 3 / 4)))
        } finally {
            bmp.recycle()
        }
        // Original-quality JPEGs are embedded without recompression.
        PdfDocs.use(out.path, null) { doc ->
            val res = doc.getPage(0).resources
            val image = res.xObjectNames.map { res.getXObject(it) }.first() as com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
            assertEquals(img.length(), image.cosObject.length)
        }
    }

    @Test
    fun transparentPngKeepsAlphaInPdf() {
        val bmp = Bitmap.createBitmap(100, 100, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.TRANSPARENT) }
        android.graphics.Canvas(bmp).drawCircle(50f, 50f, 30f, android.graphics.Paint().apply { color = Color.BLACK })
        val png = Fixtures.writeBitmap(bmp, "alpha.png")
        val out = file("alpha.pdf")
        PdfCreate.imagesToPdf(listOf(png.path), out.path, PdfCreate.ImagePdfOptions(pageSize = "a4"), OpContext.NONE)
        PdfDocs.use(out.path, null) { doc ->
            val res = doc.getPage(0).resources
            val image = res.xObjectNames.map { res.getXObject(it) }.first() as com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
            assertTrue("has soft mask", image.cosObject.getDictionaryObject(com.tom_roush.pdfbox.cos.COSName.SMASK) != null)
        }
    }

    @Test
    fun textToPdfPaginatesAndIsSearchable() {
        val text = (1..400).joinToString("\n") { "Line $it of the generated document with some words to wrap around." }
        val out = file("text.pdf")
        PdfCreate.textToPdf(Fixtures.context, text, out.path, PdfCreate.TextPdfOptions(), OpContext.NONE)
        val pages = Fixtures.pageCount(out.path)
        assertTrue("multi-page ($pages)", pages >= 5)
        assertTrue(textOf(out.path, 0).contains("Line 1 of the generated"))
        assertTrue(textOf(out.path, pages - 1).contains("Line 400"))
    }

    @Test
    fun pdfToImagesExportsEachPageAtRequestedDpi() {
        val src = textPdf("toimg.pdf", 3)
        val outDir = File(Fixtures.dir, "imgs").apply { deleteRecursively(); mkdirs() }
        val paths = PdfRaster.toImages(src.path, null, listOf(0, 2), 100f, "png", 100, outDir.path, "doc", tempDir, OpContext.NONE)
        assertEquals(2, paths.size)
        assertTrue(paths[0].endsWith("doc_1.png"))
        assertTrue(paths[1].endsWith("doc_3.png"))
        val opts = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeFile(paths[0], opts)
        assertEquals((595.27 * 100 / 72), opts.outWidth.toDouble(), 2.0)
    }

    @Test
    fun encryptedPdfCanBeRendered() {
        val src = textPdf("enc_render_src.pdf", 1)
        val enc = file("enc_render.pdf")
        com.snappdf.pro.pdf.PdfSecurity.protect(src.path, null, enc.path, "pw", null, com.snappdf.pro.pdf.PdfSecurity.Permissions())
        RasterSession.open(enc.path, "pw", tempDir).use { s ->
            assertEquals(1, s.pageCount)
            s.render(0, 50f).recycle()
        }
        assertTrue("temp copy deleted", tempDir.listFiles()!!.none { it.name.startsWith("render") })
    }

    @Test
    fun ocrProducesSearchablePdf() {
        val bmp = Fixtures.textBitmap(listOf("SNAPPDF INVOICE 2026", "TOTAL AMOUNT 4500"))
        val img = Fixtures.writeBitmap(bmp, "ocr.jpg", Bitmap.CompressFormat.JPEG, 95)
        val recognized = Ocr.recognizeFile(img.path, "latin")
        assertTrue("recognized: ${recognized["text"]}", (recognized["text"] as String).contains("INVOICE"))
        val out = file("ocr.pdf")
        val r = Ocr.imagesToSearchablePdf(Fixtures.context, listOf(img.path), out.path, "latin", "a4", OpContext.NONE)
        assertEquals(1, r.pages)
        assertTrue(r.linesRecognized >= 2)
        val extracted = textOf(out.path)
        assertTrue("searchable text: $extracted", extracted.contains("INVOICE"))
        assertTrue(extracted.contains("4500"))
    }

    @Test
    fun ocrOnExistingScannedPdfAddsHiddenText() {
        val bmp = Fixtures.textBitmap(listOf("SCANNED CONTRACT", "CLAUSE NUMBER 7"))
        val img = Fixtures.writeBitmap(bmp, "scan.jpg", Bitmap.CompressFormat.JPEG, 92)
        val scanned = file("scanned.pdf")
        PdfCreate.imagesToPdf(listOf(img.path), scanned.path, PdfCreate.ImagePdfOptions(), OpContext.NONE)
        assertTrue(textOf(scanned.path).isBlank())
        val out = file("scanned_ocr.pdf")
        val r = Ocr.ocrPdf(Fixtures.context, scanned.path, null, out.path, "latin", false, tempDir, OpContext.NONE)
        assertEquals(1, r.pages)
        assertTrue(textOf(out.path).contains("CONTRACT"))
        // Visual content is unchanged: the hidden layer is not rendered.
        assertEquals(Fixtures.pageCount(scanned.path), Fixtures.pageCount(out.path))
    }

    @Test
    fun unsupportedOcrScriptIsRejected() {
        val img = Fixtures.writeBitmap(Fixtures.solid(50, 50, Color.WHITE), "blank.png")
        try {
            Ocr.recognizeFile(img.path, "telugu")
            org.junit.Assert.fail()
        } catch (e: OpError) {
            assertEquals(OpError.UNSUPPORTED, e.code)
        }
    }

    @Test
    fun secureStoreRoundTripsAndIsEncryptedAtRest() {
        val store = SecureStore(Fixtures.context)
        val data = "signature-bytes-✓".toByteArray()
        store.write("test_sig", data)
        assertEquals(String(data), String(store.read("test_sig")!!))
        val raw = File(Fixtures.context.filesDir, "secure/test_sig.bin").readBytes()
        assertFalse(String(raw, Charsets.ISO_8859_1).contains("signature-bytes"))
        assertTrue(store.list().contains("test_sig"))
        assertTrue(store.delete("test_sig"))
        assertNull(store.read("test_sig"))
    }
}
