package com.snappdf.pro

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.snappdf.pro.Fixtures.file
import com.snappdf.pro.Fixtures.pageCount
import com.snappdf.pro.Fixtures.textOf
import com.snappdf.pro.Fixtures.textPdf
import com.snappdf.pro.pdf.PageRef
import com.snappdf.pro.pdf.PdfDocs
import com.snappdf.pro.pdf.PdfPages
import com.snappdf.pro.pdf.SourceDoc
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageFitDestination
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDDocumentOutline
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class PdfPagesTest {

    @Test
    fun mergeKeepsAllPagesInOrder() {
        val a = textPdf("merge_a.pdf", 2, "ALPHA")
        val b = textPdf("merge_b.pdf", 3, "BRAVO")
        val out = file("merged.pdf")
        val ctx = RecordingContext()
        PdfPages.merge(listOf(SourceDoc(a.path, null), SourceDoc(b.path, null)), out.path, ctx)
        assertEquals(5, pageCount(out.path))
        assertTrue(textOf(out.path, 0).contains("PAGE-1 ALPHA"))
        assertTrue(textOf(out.path, 1).contains("PAGE-2 ALPHA"))
        assertTrue(textOf(out.path, 2).contains("PAGE-1 BRAVO"))
        assertTrue(textOf(out.path, 4).contains("PAGE-3 BRAVO"))
        assertTrue("progress reported", ctx.events.isNotEmpty())
    }

    @Test
    fun mergeRequiresTwoFiles() {
        val a = textPdf("merge_single.pdf", 1)
        try {
            PdfPages.merge(listOf(SourceDoc(a.path, null)), file("x.pdf").path, OpContext.NONE)
            fail("expected error")
        } catch (e: OpError) {
            assertEquals(OpError.BAD_ARGS, e.code)
        }
    }

    @Test
    fun assembleReordersRotatesDuplicatesDeletesAndInsertsBlank() {
        val src = textPdf("organize.pdf", 4, "ORG")
        val other = textPdf("insert.pdf", 1, "INSERTED")
        val out = file("organized.pdf")
        PdfPages.assemble(
            listOf(SourceDoc(src.path, null), SourceDoc(other.path, null)),
            listOf(
                PageRef(0, 3),                    // page 4 first
                PageRef(0, 0, rotate = 90),       // page 1 rotated
                PageRef(0, 0),                    // page 1 duplicated
                PageRef(blankWidth = 300f, blankHeight = 400f),
                PageRef(1, 0),                    // page from another document
            ),                                    // pages 2 and 3 deleted
            out.path, OpContext.NONE,
        )
        assertEquals(5, pageCount(out.path))
        assertTrue(textOf(out.path, 0).contains("PAGE-4 ORG"))
        // Page 2 is rotated, so its (now vertical) text is compared compactly.
        assertTrue(Fixtures.compactTextOf(out.path, 1).contains("PAGE-1ORG"))
        assertTrue(textOf(out.path, 2).contains("PAGE-1 ORG"))
        assertTrue(textOf(out.path, 3).isBlank())
        assertTrue(textOf(out.path, 4).contains("INSERTED"))
        val all = textOf(out.path)
        assertFalse(all.contains("PAGE-2 ORG"))
        assertFalse(all.contains("PAGE-3 ORG"))
        PdfDocs.use(out.path, null) { doc ->
            assertEquals(90, doc.getPage(1).rotation)
            assertEquals(0, doc.getPage(2).rotation)
            assertEquals(300f, doc.getPage(3).mediaBox.width, 0.01f)
            // Duplicates must be distinct page objects.
            assertFalse(doc.getPage(1).cosObject === doc.getPage(2).cosObject)
        }
    }

    @Test
    fun extractingPagesDoesNotLeakRemovedPageContent() {
        val src = file("leak_src.pdf")
        textPdf("leak_tmp.pdf", 3, "TOPSECRET").copyTo(src, overwrite = true)
        // Add an outline entry pointing to page 3, which would keep it reachable.
        PdfDocs.use(src.path, null) { doc ->
            val outline = PDDocumentOutline()
            val item = PDOutlineItem().apply {
                title = "Third"
                destination = PDPageFitDestination().apply { page = doc.getPage(2) }
            }
            outline.addLast(item)
            doc.documentCatalog.documentOutline = outline
            doc.save(file("leak_src2.pdf"))
        }
        val out = file("leak_out.pdf")
        PdfPages.assemble(listOf(SourceDoc(file("leak_src2.pdf").path, null)), listOf(PageRef(0, 0)), out.path, OpContext.NONE)
        assertEquals(1, pageCount(out.path))
        assertTrue(Fixtures.anyStreamContains(out.path, "PAGE-1"))
        assertFalse("removed page content must not be in the file", Fixtures.anyStreamContains(out.path, "PAGE-3"))
        assertFalse(Fixtures.anyStreamContains(out.path, "PAGE-2"))
    }

    @Test
    fun cropSetsVisibleBox() {
        val src = textPdf("crop.pdf", 1)
        val out = file("cropped.pdf")
        PdfPages.assemble(listOf(SourceDoc(src.path, null)), listOf(PageRef(0, 0, crop = listOf(0.1, 0.2, 0.1, 0.2))), out.path, OpContext.NONE)
        PdfDocs.use(out.path, null) { doc ->
            val box = doc.getPage(0).cropBox
            assertEquals(595.27f * 0.8f, box.width, 1f)
            assertEquals(841.89f * 0.6f, box.height, 1f)
        }
    }

    @Test
    fun cancellationLeavesNoOutput() {
        val src = textPdf("cancel.pdf", 5)
        val out = file("cancelled.pdf")
        try {
            PdfPages.assemble(listOf(SourceDoc(src.path, null)), (0 until 5).map { PageRef(0, it) }, out.path, RecordingContext(cancelAfter = 2))
            fail("expected cancellation")
        } catch (e: OpError) {
            assertEquals(OpError.CANCELLED, e.code)
        }
        assertFalse(out.exists())
        // The input is untouched.
        assertEquals(5, pageCount(src.path))
    }

    @Test
    fun malformedInputsFailWithTypedErrors() {
        val notPdf = file("not_a_pdf.pdf").apply { writeText("hello, this is plain text and not a PDF") }
        expectCode(OpError.INVALID_FILE) { PdfPages.info(notPdf.path, null) }
        val missing = File(Fixtures.dir, "missing.pdf")
        expectCode(OpError.IO) { PdfPages.info(missing.path, null) }
        val garbage = file("garbage.pdf").apply { writeBytes("%PDF-1.7\n".toByteArray() + ByteArray(2048) { (it * 31).toByte() }) }
        expectCode(OpError.INVALID_FILE) { PdfPages.info(garbage.path, null) }
        val truncated = file("truncated.pdf")
        val full = textPdf("full.pdf", 3).readBytes()
        truncated.writeBytes(full.copyOf(full.size / 2))
        // PDFBox may repair a truncated file; either it opens or fails cleanly.
        try {
            PdfPages.info(truncated.path, null)
        } catch (e: OpError) {
            assertEquals(OpError.INVALID_FILE, e.code)
        }
    }

    @Test
    fun infoReportsPagesAndText() {
        val src = textPdf("info.pdf", 2, rotations = listOf(0, 90))
        val info = PdfPages.info(src.path, null)
        assertEquals(2, info["pageCount"])
        assertEquals(false, info["encrypted"])
        @Suppress("UNCHECKED_CAST")
        val pages = info["pages"] as List<Map<String, Any>>
        assertEquals(595.27, pages[0]["width"] as Double, 0.5)
        assertEquals(841.89, pages[1]["width"] as Double, 0.5) // rotated page reports display size
        assertEquals(true, info["hasText"])
        PDDocument().use { it.save(file("empty.pdf")) }
    }

    private fun expectCode(code: String, block: () -> Unit) {
        try {
            block()
            fail("expected $code")
        } catch (e: OpError) {
            assertEquals(code, e.code)
        }
    }
}
