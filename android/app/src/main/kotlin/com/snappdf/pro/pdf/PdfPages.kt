package com.snappdf.pro.pdf

import com.snappdf.pro.OpContext
import com.snappdf.pro.OpError
import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSInteger
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSNull
import com.tom_roush.pdfbox.cos.COSObject
import com.tom_roush.pdfbox.multipdf.PDFMergerUtility
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.File

data class SourceDoc(val path: String, val password: String?)

/**
 * One page of an assembled document: either page [pageIndex] of source
 * [source], or a blank page of [blankWidth] x [blankHeight] points.
 * [rotate] is added to the page's existing rotation (multiples of 90).
 */
data class PageRef(
    val source: Int = 0,
    val pageIndex: Int = 0,
    val rotate: Int = 0,
    val blankWidth: Float? = null,
    val blankHeight: Float? = null,
    /** Optional crop margins as fractions of the visible box: left, top, right, bottom. */
    val crop: List<Double>? = null,
)

object PdfPages {

    fun info(path: String, password: String?): Map<String, Any?> = PdfDocs.use(path, password) { doc ->
        val info = doc.documentInformation
        val pages = doc.pages.map { page ->
            val g = PdfDocs.geometry(page)
            mapOf(
                "width" to g.displayWidth,
                "height" to g.displayHeight,
                "rotation" to g.rotation,
            )
        }
        val acro = doc.documentCatalog.acroForm
        mapOf(
            "pageCount" to doc.numberOfPages,
            "encrypted" to doc.isEncrypted,
            "pages" to pages,
            "fileSize" to File(path).length(),
            "version" to doc.version.toDouble(),
            "hasForm" to (acro != null && acro.fields.isNotEmpty()),
            "hasXfa" to (acro?.hasXFA() == true),
            "hasText" to hasText(doc),
            "metadata" to mapOf(
                "title" to info.title,
                "author" to info.author,
                "subject" to info.subject,
                "keywords" to info.keywords,
                "creator" to info.creator,
                "producer" to info.producer,
                "created" to info.creationDate?.timeInMillis,
                "modified" to info.modificationDate?.timeInMillis,
                "hasXmp" to (doc.documentCatalog.metadata != null),
            ),
        )
    }

    /** Samples up to the first 3 pages; used to suggest OCR for scanned PDFs. */
    private fun hasText(doc: PDDocument): Boolean = try {
        val stripper = PDFTextStripper().apply {
            startPage = 1
            endPage = minOf(3, doc.numberOfPages)
        }
        stripper.getText(doc).trim().length >= 16
    } catch (e: Exception) {
        false
    }

    /**
     * Concatenates whole documents, preserving form fields, outlines and
     * other document-level structures where PDFBox supports merging them.
     */
    fun merge(sources: List<SourceDoc>, outputPath: String, ctx: OpContext) {
        if (sources.size < 2) throw OpError.badArgs("Select at least two PDFs to merge.")
        val opened = ArrayList<PDDocument>()
        try {
            val dest = PDDocument()
            opened.add(dest)
            val merger = PDFMergerUtility()
            sources.forEachIndexed { i, src ->
                ctx.checkCancelled()
                ctx.progress(i, sources.size, File(src.path).name)
                val doc = PdfDocs.open(src.path, src.password)
                opened.add(doc)
                PdfDocs.requireModifyPermission(doc)
                if (doc.isEncrypted) doc.isAllSecurityToBeRemoved = true
                merger.appendDocument(dest, doc)
            }
            ctx.progress(sources.size, sources.size)
            dest.documentInformation.producer = "SnapPDF"
            PdfDocs.save(dest, outputPath)
        } finally {
            opened.forEach { runCatching { it.close() } }
        }
    }

    /**
     * Builds a new document from [pages]. The first source is the "base"
     * document: its catalog (forms, metadata, outlines) is kept and its pages
     * are reused in place; repeated pages and pages from other sources are
     * shallow copies that share content streams and resources.
     */
    fun assemble(sources: List<SourceDoc>, pages: List<PageRef>, outputPath: String, ctx: OpContext) {
        if (sources.isEmpty()) throw OpError.badArgs("No source document.")
        if (pages.isEmpty()) throw OpError.badArgs("The result would have no pages.")
        val docs = ArrayList<PDDocument>()
        try {
            sources.forEach { docs.add(PdfDocs.open(it.path, it.password)) }
            docs.forEach { PdfDocs.requireModifyPermission(it) }
            val base = docs[0]
            val sourcePages = docs.map { d -> d.pages.toList() }
            val used = HashSet<Pair<Int, Int>>()
            val result = ArrayList<PDPage>(pages.size)
            var lastSize = PDRectangle.A4

            // Pass 1: create page objects from the untouched originals, so
            // duplicates do not inherit rotation/crop applied to other copies.
            pages.forEachIndexed { i, ref ->
                ctx.checkCancelled()
                ctx.progress(i, pages.size)
                val page: PDPage = if (ref.blankWidth != null && ref.blankHeight != null) {
                    PDPage(PDRectangle(ref.blankWidth, ref.blankHeight))
                } else {
                    if (ref.source !in docs.indices) throw OpError.badArgs("Unknown source ${ref.source}.")
                    val list = sourcePages[ref.source]
                    if (ref.pageIndex !in list.indices) {
                        throw OpError.badArgs("Page ${ref.pageIndex + 1} does not exist in ${File(sources[ref.source].path).name}.")
                    }
                    val original = list[ref.pageIndex]
                    val key = ref.source to ref.pageIndex
                    if (ref.source == 0 && used.add(key)) {
                        materializeInherited(original)
                        original
                    } else {
                        shallowCopy(original)
                    }
                }
                result.add(page)
            }
            // Pass 2: apply per-reference rotation and crop.
            result.forEachIndexed { i, page ->
                val ref = pages[i]
                if (ref.rotate != 0) {
                    page.rotation = PageGeometry.normalizeRotation(page.rotation + ref.rotate)
                }
                ref.crop?.let { applyCrop(page, it) }
                lastSize = page.mediaBox
            }

            // Replace the base document's page tree with a flat tree.
            val root = base.documentCatalog.cosObject.getCOSDictionary(COSName.PAGES)
                ?: throw OpError(OpError.INVALID_FILE, "The PDF has no page tree.")
            val kids = COSArray()
            result.forEach { p ->
                p.cosObject.setItem(COSName.PARENT, root)
                kids.add(p.cosObject)
            }
            root.setItem(COSName.KIDS, kids)
            root.setItem(COSName.COUNT, COSInteger.get(result.size.toLong()))
            // Inherited attributes have been materialised on every page.
            root.removeItem(COSName.RESOURCES)
            root.removeItem(COSName.MEDIA_BOX)
            root.removeItem(COSName.CROP_BOX)
            root.removeItem(COSName.ROTATE)

            result.forEach { p ->
                p.annotations.forEach { a -> a.page = p }
            }
            // Pages that were dropped must not stay reachable through outlines,
            // named destinations, form fields or structure trees; otherwise
            // their content would still be written into the output file.
            val kept = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Any, Boolean>())
            result.forEach { kept.add(it.cosObject) }
            val removed = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Any, Boolean>())
            sourcePages[0].forEach { if (!kept.contains(it.cosObject)) removed.add(it.cosObject) }
            if (removed.isNotEmpty()) {
                detachReferences(base.documentCatalog.cosObject, removed)
                pruneFormFields(base, removed)
            }
            ctx.progress(pages.size, pages.size)
            if (lastSize.width <= 0f) throw OpError(OpError.INVALID_FILE, "Invalid page size.")
            PdfDocs.save(base, outputPath)
        } finally {
            docs.forEach { runCatching { it.close() } }
        }
    }

    /**
     * Walks the object graph from [root] and replaces every reference to an
     * object in [targets] with null.
     */
    internal fun detachReferences(root: COSBase, targets: Set<Any>) {
        val visited = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Any, Boolean>())
        val stack = ArrayDeque<COSBase>()
        stack.add(root)
        while (stack.isNotEmpty()) {
            val node = resolve(stack.removeLast()) ?: continue
            if (!visited.add(node)) continue
            when (node) {
                is COSDictionary -> {
                    for (key in node.keySet().toList()) {
                        val value = node.getItem(key) ?: continue
                        val resolved = resolve(value)
                        if (resolved != null && targets.contains(resolved)) {
                            node.setItem(key, COSNull.NULL)
                        } else if (resolved is COSDictionary || resolved is COSArray) {
                            stack.add(resolved)
                        }
                    }
                }
                is COSArray -> {
                    for (i in 0 until node.size()) {
                        val resolved = resolve(node.get(i))
                        if (resolved != null && targets.contains(resolved)) {
                            node.set(i, COSNull.NULL)
                        } else if (resolved is COSDictionary || resolved is COSArray) {
                            stack.add(resolved)
                        }
                    }
                }
            }
        }
    }

    private fun resolve(value: COSBase?): COSBase? = if (value is COSObject) value.getObject() else value

    /** Removes form fields whose widgets were all on removed pages. */
    private fun pruneFormFields(doc: PDDocument, removedPages: Set<Any>) {
        val form = doc.documentCatalog.acroForm ?: return
        fun isOrphan(widgetDict: COSDictionary): Boolean {
            val p = resolve(widgetDict.getItem(COSName.P))
            return p == null || p is COSNull || removedPages.contains(p)
        }
        val keep = form.fields.filter { field ->
            val widgets = field.widgets
            widgets.isEmpty() || widgets.any { !isOrphan(it.cosObject) }
        }
        if (keep.size != form.fields.size) form.fields = keep
    }

    /**
     * Removes the widgets in [widgets] from the form field tree, and any field
     * left without widgets or children, so their values are not kept.
     */
    internal fun pruneFieldsByWidgets(doc: PDDocument, widgets: Set<Any>) {
        val acro = doc.documentCatalog.acroForm ?: return
        val fields = acro.cosObject.getDictionaryObject(COSName.FIELDS) as? COSArray ?: return
        pruneKids(fields, widgets, 0)
        if (fields.size() == 0) {
            doc.documentCatalog.cosObject.removeItem(COSName.ACRO_FORM)
        }
    }

    private fun pruneKids(kids: COSArray, widgets: Set<Any>, depth: Int) {
        if (depth > 32) return
        for (i in kids.size() - 1 downTo 0) {
            val dict = resolve(kids.get(i)) as? COSDictionary ?: continue
            if (widgets.contains(dict)) {
                kids.remove(i)
                continue
            }
            val childKids = dict.getDictionaryObject(COSName.KIDS) as? COSArray ?: continue
            pruneKids(childKids, widgets, depth + 1)
            if (childKids.size() == 0) kids.remove(i)
        }
    }

    /** Copies inheritable attributes from ancestors onto the page itself. */
    private fun materializeInherited(page: PDPage) {
        val dict = page.cosObject
        page.resources?.let { dict.setItem(COSName.RESOURCES, it.cosObject) }
        dict.setItem(COSName.MEDIA_BOX, page.mediaBox.cosArray)
        if (dict.getDictionaryObject(COSName.CROP_BOX) == null && hasInherited(dict, COSName.CROP_BOX)) {
            dict.setItem(COSName.CROP_BOX, page.cropBox.cosArray)
        }
        dict.setInt(COSName.ROTATE, page.rotation)
    }

    private fun hasInherited(dict: COSDictionary, key: COSName): Boolean {
        var node = dict.getCOSDictionary(COSName.PARENT)
        var depth = 0
        while (node != null && depth < 64) {
            if (node.getDictionaryObject(key) != null) return true
            node = node.getCOSDictionary(COSName.PARENT)
            depth++
        }
        return false
    }

    private fun shallowCopy(original: PDPage): PDPage {
        val src = original.cosObject
        val copy = COSDictionary()
        for ((key, value) in src.entrySet()) {
            if (key == COSName.PARENT || key == COSName.ANNOTS || key == COSName.STRUCT_PARENTS ||
                key == COSName.getPDFName("B")
            ) continue
            copy.setItem(key, value)
        }
        val page = PDPage(copy)
        original.resources?.let { copy.setItem(COSName.RESOURCES, it.cosObject) }
        copy.setItem(COSName.MEDIA_BOX, original.mediaBox.cosArray)
        copy.setItem(COSName.CROP_BOX, original.cropBox.cosArray)
        copy.setInt(COSName.ROTATE, original.rotation)
        // Annotations are copied individually: sharing annotation dictionaries
        // between pages is not allowed. Form widgets are dropped from copies
        // because a widget can only belong to one page.
        val annots = original.annotations
            .filter { it.subtype != "Widget" && it.subtype != "Popup" }
            .map { a ->
                val ad = COSDictionary()
                for ((k, v) in a.cosObject.entrySet()) {
                    if (k == COSName.P || k == COSName.getPDFName("Popup") || k == COSName.PARENT) continue
                    ad.setItem(k, v)
                }
                com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotation.createAnnotation(ad)
            }
        if (annots.isNotEmpty()) page.annotations = annots
        return page
    }

    private fun applyCrop(page: PDPage, margins: List<Double>) {
        if (margins.size != 4) throw OpError.badArgs("Crop needs 4 margins.")
        val (l, t, r, b) = margins
        if (margins.any { it < 0 || it >= 0.9 } || l + r >= 0.95 || t + b >= 0.95) {
            throw OpError.badArgs("Crop margins are too large.")
        }
        val g = PdfDocs.geometry(page)
        // Margins are given in display orientation; convert the two display
        // corners of the kept area to user space and build an axis-aligned box.
        val m = g.displayToUser
        val (x1, y1) = m.apply(l * g.displayWidth, t * g.displayHeight)
        val (x2, y2) = m.apply((1 - r) * g.displayWidth, (1 - b) * g.displayHeight)
        val box = PDRectangle(
            minOf(x1, x2).toFloat(), minOf(y1, y2).toFloat(),
            kotlin.math.abs(x2 - x1).toFloat(), kotlin.math.abs(y2 - y1).toFloat(),
        )
        page.cropBox = box
    }

    /** Extracts plain text; returns one string per requested page. */
    fun extractText(path: String, password: String?, pageIndices: List<Int>?, ctx: OpContext): List<String> =
        PdfDocs.use(path, password) { doc ->
            PdfDocs.requireExtractPermission(doc)
            val indices = PdfDocs.pageIndices(pageIndices, doc.numberOfPages)
            val stripper = PDFTextStripper().apply { sortByPosition = true }
            indices.mapIndexed { i, index ->
                ctx.checkCancelled()
                ctx.progress(i, indices.size)
                stripper.startPage = index + 1
                stripper.endPage = index + 1
                stripper.getText(doc)
            }
        }
}
