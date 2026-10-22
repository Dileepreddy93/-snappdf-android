package com.snappdf.pro.pdf

import com.snappdf.pro.OpError
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import java.io.File
import java.io.FileInputStream
import java.io.IOException

/** Upper bound for input files; protects the device from pathological inputs. */
const val MAX_PDF_BYTES: Long = 512L * 1024 * 1024

object PdfDocs {
    @Volatile
    var tempDir: File? = null

    private fun memorySetting(): MemoryUsageSetting {
        // Keep up to 48 MB of document data on the heap and spill the rest to
        // a private temp directory, so large documents do not exhaust memory.
        val setting = MemoryUsageSetting.setupMixed(48L * 1024 * 1024)
        tempDir?.let { dir ->
            dir.mkdirs()
            setting.setTempDir(dir)
        }
        return setting
    }

    /**
     * Opens a PDF. Throws [OpError] with PASSWORD_REQUIRED / WRONG_PASSWORD for
     * encrypted documents and INVALID_FILE for malformed input.
     */
    fun open(path: String, password: String?): PDDocument {
        val file = File(path)
        if (!file.isFile) throw OpError(OpError.IO, "File not found: ${file.name}")
        if (file.length() > MAX_PDF_BYTES) {
            throw OpError(OpError.TOO_LARGE, "This PDF is larger than ${MAX_PDF_BYTES / (1024 * 1024)} MB.")
        }
        if (!looksLikePdf(file)) throw OpError(OpError.INVALID_FILE, "${file.name} is not a PDF file.")
        try {
            return PDDocument.load(file, password ?: "", memorySetting())
        } catch (e: InvalidPasswordException) {
            throw if (password.isNullOrEmpty()) {
                OpError(OpError.PASSWORD_REQUIRED, "This PDF is password protected.", e)
            } else {
                OpError(OpError.WRONG_PASSWORD, "The password is incorrect.", e)
            }
        } catch (e: OutOfMemoryError) {
            throw OpError(OpError.OUT_OF_MEMORY, "Not enough memory to open this PDF.")
        } catch (e: IOException) {
            throw OpError(OpError.INVALID_FILE, "This PDF is damaged or uses an unsupported structure.", e)
        }
    }

    /** True when the file starts with a %PDF header within the first 1 KB. */
    fun looksLikePdf(file: File): Boolean = try {
        FileInputStream(file).use { input ->
            val buffer = ByteArray(1024)
            val read = input.read(buffer)
            read > 4 && String(buffer, 0, read, Charsets.ISO_8859_1).contains("%PDF-")
        }
    } catch (e: IOException) {
        false
    }

    /**
     * Saves to [outputPath] atomically: the document is written to a sibling
     * temp file first and renamed only after a successful write, so a failure
     * never leaves a truncated output and never touches the input.
     */
    fun save(doc: PDDocument, outputPath: String, removeSecurity: Boolean = true) {
        val out = File(outputPath)
        out.parentFile?.mkdirs()
        requireModifyPermission(doc)
        val tmp = File(out.parentFile, ".${out.name}.${System.nanoTime()}.part")
        try {
            if (removeSecurity && doc.isEncrypted) doc.isAllSecurityToBeRemoved = true
            doc.save(tmp)
            if (out.exists() && !out.delete()) throw IOException("Cannot replace ${out.name}")
            if (!tmp.renameTo(out)) throw IOException("Cannot finalise ${out.name}")
        } catch (e: OutOfMemoryError) {
            tmp.delete()
            throw OpError(OpError.OUT_OF_MEMORY, "Not enough memory to save this PDF.")
        } catch (e: IOException) {
            tmp.delete()
            throw OpError(OpError.IO, "Could not save the PDF: ${e.message}", e)
        }
    }

    /**
     * Encrypted PDFs opened without the owner password may forbid changes.
     * Producing a modified copy then requires the owner password.
     */
    fun requireModifyPermission(doc: PDDocument) {
        if (!doc.isEncrypted) return
        val ap = doc.currentAccessPermission
        if (!ap.isOwnerPermission && !ap.canModify()) {
            throw OpError(
                OpError.RESTRICTED,
                "The owner of this PDF does not allow changes. Enter the owner password to continue.",
            )
        }
    }

    fun requireExtractPermission(doc: PDDocument) {
        if (!doc.isEncrypted) return
        val ap = doc.currentAccessPermission
        if (!ap.isOwnerPermission && !ap.canExtractContent()) {
            throw OpError(
                OpError.RESTRICTED,
                "The owner of this PDF does not allow copying its content. Enter the owner password to continue.",
            )
        }
    }

    fun geometry(page: PDPage): PageGeometry {
        val box: PDRectangle = page.cropBox
        return PageGeometry(
            box.lowerLeftX.toDouble(), box.lowerLeftY.toDouble(),
            box.width.toDouble(), box.height.toDouble(),
            page.rotation,
        )
    }

    inline fun <T> use(path: String, password: String?, block: (PDDocument) -> T): T {
        val doc = open(path, password)
        try {
            return block(doc)
        } finally {
            doc.close()
        }
    }

    /** Parses 0-based page indices; null/empty means all pages. */
    fun pageIndices(arg: List<Int>?, pageCount: Int): List<Int> {
        if (arg.isNullOrEmpty()) return (0 until pageCount).toList()
        val bad = arg.firstOrNull { it < 0 || it >= pageCount }
        if (bad != null) throw OpError.badArgs("Page ${bad + 1} does not exist (document has $pageCount pages).")
        return arg.distinct().sorted()
    }
}
