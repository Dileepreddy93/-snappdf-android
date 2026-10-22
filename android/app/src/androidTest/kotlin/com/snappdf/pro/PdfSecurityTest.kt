package com.snappdf.pro

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.snappdf.pro.Fixtures.file
import com.snappdf.pro.Fixtures.textOf
import com.snappdf.pro.Fixtures.textPdf
import com.snappdf.pro.pdf.PdfCompress
import com.snappdf.pro.pdf.PdfDocs
import com.snappdf.pro.pdf.PdfPages
import com.snappdf.pro.pdf.PdfSecurity
import com.snappdf.pro.pdf.PdfStamp
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PdfSecurityTest {

    private fun expectCode(code: String, block: () -> Unit) {
        try {
            block()
            fail("expected $code")
        } catch (e: OpError) {
            assertEquals(code, e.code)
        }
    }

    @Test
    fun protectRequiresPasswordAndUsesAes256() {
        val src = textPdf("plain.pdf", 2, "CONFIDENTIAL")
        val out = file("protected.pdf")
        PdfSecurity.protect(src.path, null, out.path, "s3cret!", null, PdfSecurity.Permissions())
        expectCode(OpError.PASSWORD_REQUIRED) { PdfPages.info(out.path, null) }
        expectCode(OpError.WRONG_PASSWORD) { PdfPages.info(out.path, "wrong") }
        PdfDocs.use(out.path, "s3cret!") { doc ->
            assertTrue(doc.isEncrypted)
            assertEquals(256, doc.encryption.length)
            assertEquals(2, doc.numberOfPages)
        }
        assertTrue(textOf(out.path, password = "s3cret!").contains("CONFIDENTIAL"))
        // The plaintext must not be visible in the file bytes.
        assertFalse(Fixtures.anyStreamContains(out.path, "CONFIDENTIAL"))
    }

    @Test
    fun unlockAndChangePassword() {
        val src = textPdf("pw_src.pdf", 1, "UNLOCKME")
        val locked = file("pw_locked.pdf")
        PdfSecurity.protect(src.path, null, locked.path, "old-pass", null, PdfSecurity.Permissions())

        val changed = file("pw_changed.pdf")
        PdfSecurity.protect(locked.path, "old-pass", changed.path, "new-pass", null, PdfSecurity.Permissions())
        expectCode(OpError.WRONG_PASSWORD) { PdfPages.info(changed.path, "old-pass") }
        assertEquals(1, PdfPages.info(changed.path, "new-pass")["pageCount"])

        val unlocked = file("pw_unlocked.pdf")
        expectCode(OpError.PASSWORD_REQUIRED) { PdfSecurity.unlock(changed.path, null, unlocked.path) }
        PdfSecurity.unlock(changed.path, "new-pass", unlocked.path)
        PdfDocs.use(unlocked.path, null) { assertFalse(it.isEncrypted) }
        assertTrue(textOf(unlocked.path).contains("UNLOCKME"))
    }

    @Test
    fun ownerRestrictionsAreEnforcedWithoutOwnerPassword() {
        val src = textPdf("restrict_src.pdf", 1)
        val restricted = file("restricted.pdf")
        PdfDocs.use(src.path, null) { doc ->
            val ap = AccessPermission().apply {
                setCanModify(false)
                setCanExtractContent(false)
            }
            doc.protect(StandardProtectionPolicy("owner-pw", "", ap).apply { encryptionKeyLength = 256 })
            doc.save(restricted)
        }
        // Opens without a password (empty user password) but changes are refused.
        assertEquals(1, PdfPages.info(restricted.path, null)["pageCount"])
        expectCode(OpError.RESTRICTED) {
            PdfStamp.pageNumbers(
                Fixtures.context, restricted.path, null, file("r_out.pdf").path,
                PdfStamp.PageNumbers("{n}", "bottom-center", 10f, 0xFF000000, 20.0, 1, false, null, null, null),
                OpContext.NONE,
            )
        }
        expectCode(OpError.RESTRICTED) { PdfSecurity.unlock(restricted.path, null, file("r_unlock.pdf").path) }
        expectCode(OpError.RESTRICTED) { PdfPages.extractText(restricted.path, null, null, OpContext.NONE) }
        // With the owner password everything is allowed.
        PdfSecurity.unlock(restricted.path, "owner-pw", file("r_unlocked.pdf").path)
        PdfDocs.use(file("r_unlocked.pdf").path, null) { assertFalse(it.isEncrypted) }
    }

    @Test
    fun metadataCanBeEditedAndRemoved() {
        val src = file("meta_src.pdf")
        PdfDocs.use(textPdf("meta_tmp.pdf", 1).path, null) { doc ->
            doc.documentInformation.apply {
                title = "Secret title"
                author = "Jane Doe"
                creator = "Word"
            }
            doc.save(src)
        }
        val edited = file("meta_edit.pdf")
        PdfSecurity.setMetadata(src.path, null, edited.path, PdfSecurity.Metadata("New", "Me", null, "a,b", null, null), false)
        PdfDocs.use(edited.path, null) { doc ->
            assertEquals("New", doc.documentInformation.title)
            assertEquals("Me", doc.documentInformation.author)
            assertNull(doc.documentInformation.creator)
        }
        val stripped = file("meta_strip.pdf")
        PdfSecurity.setMetadata(src.path, null, stripped.path, null, true)
        PdfDocs.use(stripped.path, null) { doc ->
            assertNull(doc.documentInformation.title)
            assertNull(doc.documentInformation.author)
            assertNull(doc.documentCatalog.metadata)
        }
        assertFalse(Fixtures.anyStreamContains(stripped.path, "Jane Doe"))
    }

    @Test
    fun compressionShrinksImagePdfAndKeepsPages() {
        val src = Fixtures.imageHeavyPdf("heavy.pdf", 2)
        val out = file("heavy_small.pdf")
        val r = PdfCompress.compress(src.path, null, out.path, PdfCompress.Options(120, 0.6f, true), OpContext.NONE)
        assertEquals(2, r.pageCount)
        assertTrue("output ${r.outputBytes} < input ${r.inputBytes}", r.outputBytes < r.inputBytes / 3)
        assertEquals(1, r.imagesRecompressed) // shared image is processed once
        assertEquals(2, Fixtures.pageCount(out.path))
        assertTrue(textOf(out.path).contains("SCANNED PAGE 2"))
        PdfDocs.use(out.path, null) { doc ->
            val img = doc.getPage(0).resources.xObjectNames.map { doc.getPage(0).resources.getXObject(it) }
                .filterIsInstance<com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject>().first()
            // A4 long side at 120 dpi ~ 1404 px.
            assertTrue("downsampled to ${img.height}", img.height <= 1404)
        }
    }

    @Test
    fun compressionNeverEnlargesTextOnlyPdf() {
        val src = textPdf("textonly.pdf", 3)
        val out = file("textonly_c.pdf")
        val r = PdfCompress.compress(src.path, null, out.path, PdfCompress.Options(150, 0.7f, true), OpContext.NONE)
        assertEquals(0, r.imagesRecompressed)
        assertEquals(3, r.pageCount)
        assertTrue(textOf(out.path).contains("PAGE-3"))
    }

    @Test
    fun watermarkAndPageNumbersAreAdded() {
        val src = textPdf("stamp.pdf", 3, rotations = listOf(0, 90, 270))
        val wm = file("stamp_wm.pdf")
        PdfStamp.watermark(
            Fixtures.context, src.path, null, wm.path,
            PdfStamp.Watermark("DRAFT COPY", null, 40f, 0xFFFF0000, 0.3f, -45.0, "center", 0.4, null),
            OpContext.NONE,
        )
        for (i in 0 until 3) assertTrue(Fixtures.compactTextOf(wm.path, i).contains("DRAFTCOPY"))
        val numbered = file("stamp_num.pdf")
        PdfStamp.pageNumbers(
            Fixtures.context, wm.path, null, numbered.path,
            PdfStamp.PageNumbers("Page {n} of {total}", "bottom-center", 10f, 0xFF000000, 24.0, 1, false, "Header text", null, null),
            OpContext.NONE,
        )
        assertTrue(textOf(numbered.path, 0).contains("Page 1 of 3"))
        assertTrue(textOf(numbered.path, 2).contains("Page 3 of 3"))
        assertTrue(textOf(numbered.path, 1).contains("Header text"))
    }
}
