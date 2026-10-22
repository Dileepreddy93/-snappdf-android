package com.snappdf.pro.pdf

import com.snappdf.pro.OpError
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocumentInformation
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import java.util.Calendar

object PdfSecurity {

    data class Permissions(
        val print: Boolean = true,
        val copy: Boolean = true,
        val modify: Boolean = true,
        val annotate: Boolean = true,
        val fillForms: Boolean = true,
    )

    /**
     * Encrypts with AES-256 (PDF 2.0 / revision 6 security handler).
     * The owner password controls permissions; when blank a random one is used
     * so the permission restrictions cannot be lifted with an empty password.
     */
    fun protect(
        input: String,
        currentPassword: String?,
        output: String,
        userPassword: String,
        ownerPassword: String?,
        permissions: Permissions,
    ) {
        if (userPassword.isEmpty()) throw OpError.badArgs("Enter a password.")
        if (userPassword.length > 127) throw OpError.badArgs("Passwords can be at most 127 characters.")
        PdfDocs.use(input, currentPassword) { doc ->
            if (doc.isEncrypted) doc.isAllSecurityToBeRemoved = true
            val ap = AccessPermission().apply {
                setCanPrint(permissions.print)
                setCanPrintFaithful(permissions.print)
                setCanExtractContent(permissions.copy)
                setCanExtractForAccessibility(true)
                setCanModify(permissions.modify)
                setCanAssembleDocument(permissions.modify)
                setCanModifyAnnotations(permissions.annotate)
                setCanFillInForm(permissions.fillForms)
            }
            val owner = ownerPassword?.takeIf { it.isNotEmpty() }
                ?: java.util.UUID.randomUUID().toString() + java.util.UUID.randomUUID().toString()
            val policy = StandardProtectionPolicy(owner, userPassword, ap).apply {
                encryptionKeyLength = 256
            }
            // Re-open state: protection replaces any previous security handler.
            doc.isAllSecurityToBeRemoved = false
            doc.protect(policy)
            PdfDocs.save(doc, output, removeSecurity = false)
        }
    }

    /** Writes an unencrypted copy. Requires the correct password. */
    fun unlock(input: String, password: String?, output: String) {
        PdfDocs.use(input, password) { doc ->
            if (!doc.isEncrypted) throw OpError(OpError.UNSUPPORTED, "This PDF is not password protected.")
            PdfDocs.save(doc, output, removeSecurity = true)
        }
    }

    data class Metadata(
        val title: String?, val author: String?, val subject: String?,
        val keywords: String?, val creator: String?, val producer: String?,
    )

    /**
     * Replaces document metadata. With [removeAll] the Info dictionary, XMP
     * stream, page-level metadata/PieceInfo and thumbnails are removed.
     */
    fun setMetadata(input: String, password: String?, output: String, metadata: Metadata?, removeAll: Boolean) {
        PdfDocs.use(input, password) { doc ->
            if (removeAll) {
                doc.documentInformation = PDDocumentInformation()
                doc.documentCatalog.metadata = null
                doc.documentCatalog.cosObject.removeItem(COSName.PIECE_INFO)
                doc.pages.forEach { page ->
                    page.cosObject.removeItem(COSName.METADATA)
                    page.cosObject.removeItem(COSName.PIECE_INFO)
                    page.cosObject.removeItem(COSName.getPDFName("Thumb"))
                }
                // Remove the trailer document ID, which can link a file to its origin.
                doc.document.trailer.removeItem(COSName.ID)
            } else if (metadata != null) {
                val info = doc.documentInformation
                info.title = metadata.title?.ifBlank { null }
                info.author = metadata.author?.ifBlank { null }
                info.subject = metadata.subject?.ifBlank { null }
                info.keywords = metadata.keywords?.ifBlank { null }
                info.creator = metadata.creator?.ifBlank { null }
                info.producer = metadata.producer?.ifBlank { null }
                info.modificationDate = Calendar.getInstance()
                // XMP would otherwise contradict the new Info values.
                doc.documentCatalog.metadata = null
            }
            PdfDocs.save(doc, output)
        }
    }
}
