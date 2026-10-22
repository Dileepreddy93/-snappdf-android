package com.snappdf.pro.pdf

import android.graphics.Bitmap
import android.graphics.Rect
import com.snappdf.pro.OpContext
import com.snappdf.pro.OpError
import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSStream
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDDocumentInformation
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import java.io.File
import java.util.IdentityHashMap
import kotlin.math.ceil
import kotlin.math.max

object PdfCompress {

    data class Options(
        /** Images are downsampled so they need no more than this resolution at full-page size. */
        val maxDpi: Int,
        /** JPEG quality, 0..1. */
        val jpegQuality: Float,
        val stripMetadata: Boolean,
        /** Convert recompressed images to grayscale. */
        val grayscale: Boolean = false,
    )

    data class Result(
        val inputBytes: Long,
        val outputBytes: Long,
        val imagesRecompressed: Int,
        val imagesKept: Int,
        val pageCount: Int,
    )

    private val SKIP_FILTERS = setOf("JBIG2Decode", "CCITTFaxDecode", "JPXDecode")

    fun compress(input: String, password: String?, output: String, opts: Options, ctx: OpContext): Result {
        val inputBytes = File(input).length()
        var recompressed = 0
        var kept = 0
        val pageCount = PdfDocs.use(input, password) { doc ->
            PdfDocs.requireModifyPermission(doc)
            val replaced = IdentityHashMap<COSBase, PDImageXObject?>()
            val visitedForms = IdentityHashMap<COSBase, Boolean>()
            val pages = doc.pages.toList()
            pages.forEachIndexed { i, page ->
                ctx.checkCancelled()
                ctx.progress(i, pages.size)
                val g = PdfDocs.geometry(page)
                // Longest side a full-page image needs at maxDpi.
                val maxPixels = ceil(max(g.displayWidth, g.displayHeight) / 72.0 * opts.maxDpi).toInt()
                page.resources?.let {
                    processResources(doc, it, maxPixels, opts, replaced, visitedForms, ctx) { ok ->
                        if (ok) recompressed++ else kept++
                    }
                }
                compressContentStreams(page)
                if (opts.stripMetadata) {
                    page.cosObject.removeItem(COSName.METADATA)
                    page.cosObject.removeItem(COSName.PIECE_INFO)
                    page.cosObject.removeItem(COSName.getPDFName("Thumb"))
                }
            }
            if (opts.stripMetadata) {
                doc.documentInformation = PDDocumentInformation().apply { producer = "SnapPDF" }
                doc.documentCatalog.metadata = null
                doc.documentCatalog.cosObject.removeItem(COSName.PIECE_INFO)
            }
            ctx.progress(pages.size, pages.size)
            PdfDocs.save(doc, output)
            pages.size
        }
        return Result(inputBytes, File(output).length(), recompressed, kept, pageCount)
    }

    private fun processResources(
        doc: PDDocument,
        resources: PDResources,
        maxPixels: Int,
        opts: Options,
        replaced: IdentityHashMap<COSBase, PDImageXObject?>,
        visitedForms: IdentityHashMap<COSBase, Boolean>,
        ctx: OpContext,
        onImage: (Boolean) -> Unit,
    ) {
        for (name in resources.xObjectNames.toList()) {
            ctx.checkCancelled()
            val xobject = try {
                resources.getXObject(name)
            } catch (e: Exception) {
                null
            } ?: continue
            when (xobject) {
                is PDImageXObject -> {
                    val key = xobject.cosObject
                    if (replaced.containsKey(key)) {
                        replaced[key]?.let { resources.put(name, it) }
                        continue
                    }
                    val replacement = try {
                        recompress(doc, xobject, maxPixels, opts)
                    } catch (e: OutOfMemoryError) {
                        null
                    } catch (e: Exception) {
                        null
                    }
                    replaced[key] = replacement
                    if (replacement != null) {
                        resources.put(name, replacement)
                        onImage(true)
                    } else {
                        onImage(false)
                    }
                }
                is PDFormXObject -> {
                    val key = xobject.cosObject
                    if (visitedForms.put(key, true) == null) {
                        xobject.resources?.let { processResources(doc, it, maxPixels, opts, replaced, visitedForms, ctx, onImage) }
                    }
                }
            }
        }
    }

    /** Returns a smaller replacement image, or null to keep the original. */
    private fun recompress(doc: PDDocument, image: PDImageXObject, maxPixels: Int, opts: Options): PDImageXObject? {
        val stream: COSStream = image.cosObject
        if (image.isStencil) return null
        if (image.width * image.height < 96 * 96) return null
        if (image.bitsPerComponent == 1) return null
        val filters = image.stream.filters.map { it.name }
        if (filters.any { it in SKIP_FILTERS }) return null
        val colorSpaceName = runCatching { image.colorSpace.name }.getOrNull()
        if (colorSpaceName == "Indexed" && filters.contains("FlateDecode") && image.width * image.height < 1_000_000) return null

        val originalBytes = stream.length
        val longest = max(image.width, image.height)
        val alreadyJpeg = filters.contains("DCTDecode")
        // Leave JPEGs that are already at or below the target resolution
        // alone: recompressing them only adds generation loss.
        if (alreadyJpeg && longest <= maxPixels && opts.jpegQuality >= 0.8f && !opts.grayscale) return null

        var subsample = 1
        while (longest / (subsample * 2) >= maxPixels) subsample *= 2
        val bitmap: Bitmap = image.getImage(Rect(0, 0, image.width, image.height), subsample) ?: return null
        var scaled = bitmap
        try {
            val currentLongest = max(bitmap.width, bitmap.height)
            if (currentLongest > maxPixels) {
                val s = maxPixels.toFloat() / currentLongest
                scaled = Bitmap.createScaledBitmap(bitmap, max(1, (bitmap.width * s).toInt()), max(1, (bitmap.height * s).toInt()), true)
            }
            val opaque = if (opts.grayscale) toGray(scaled) else PdfCreate.flattenOnWhite(scaled)
            val replacement = try {
                JPEGFactory.createFromImage(doc, opaque, opts.jpegQuality)
            } finally {
                if (opaque !== scaled) opaque.recycle()
            }
            if (replacement.cosObject.length >= originalBytes * 0.95) return null
            // Keep transparency and masking information from the original.
            stream.getDictionaryObject(COSName.SMASK)?.let { replacement.cosObject.setItem(COSName.SMASK, it) }
            stream.getDictionaryObject(COSName.MASK)?.let { replacement.cosObject.setItem(COSName.MASK, it) }
            stream.getDictionaryObject(COSName.INTERPOLATE)?.let { replacement.cosObject.setItem(COSName.INTERPOLATE, it) }
            return replacement
        } finally {
            if (scaled !== bitmap) scaled.recycle()
            bitmap.recycle()
        }
    }

    private fun toGray(src: Bitmap): Bitmap {
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(out)
        canvas.drawColor(android.graphics.Color.WHITE)
        val paint = android.graphics.Paint().apply {
            colorFilter = android.graphics.ColorMatrixColorFilter(android.graphics.ColorMatrix().apply { setSaturation(0f) })
        }
        canvas.drawBitmap(src, 0f, 0f, paint)
        out.setHasAlpha(false)
        return out
    }

    /** Applies Flate compression to uncompressed page content streams. */
    private fun compressContentStreams(page: com.tom_roush.pdfbox.pdmodel.PDPage) {
        val contents = page.cosObject.getDictionaryObject(COSName.CONTENTS)
        val streams = when (contents) {
            is COSStream -> listOf(contents)
            is com.tom_roush.pdfbox.cos.COSArray -> contents.mapNotNull { (if (it is com.tom_roush.pdfbox.cos.COSObject) it.getObject() else it) as? COSStream }
            else -> emptyList()
        }
        for (s in streams) {
            if (s.filters != null) continue
            val data = s.createRawInputStream().use { it.readBytes() }
            if (data.size < 256) continue
            s.createOutputStream(COSName.FLATE_DECODE).use { it.write(data) }
        }
    }
}
