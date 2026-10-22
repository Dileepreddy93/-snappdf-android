package com.snappdf.pro.pdf

import android.content.Context
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.font.PDType0Font

/**
 * Embeds bundled Noto fonts (SIL OFL) into documents. Fonts are subset so only
 * the glyphs that are used end up in the output.
 *
 * Limitation: PDFBox does not perform complex-script shaping, so visible
 * Devanagari/Telugu text may render without conjunct ligatures. Invisible OCR
 * text layers are unaffected (they only need correct Unicode mapping).
 */
class Fonts(private val context: Context, private val doc: PDDocument) {
    private val cache = HashMap<String, PDFont>()

    fun latin(bold: Boolean = false): PDFont =
        load(if (bold) "fonts/NotoSans-Bold.ttf" else "fonts/NotoSans-Regular.ttf")

    /** Picks a font able to display most of [text]. */
    fun forText(text: String, bold: Boolean = false): PDFont = when (dominantScript(text)) {
        Script.DEVANAGARI -> load("fonts/NotoSansDevanagari-Regular.ttf")
        Script.TELUGU -> load("fonts/NotoSansTelugu-Regular.ttf")
        Script.LATIN -> latin(bold)
    }

    private fun load(asset: String): PDFont = cache.getOrPut(asset) {
        context.assets.open(asset).use { PDType0Font.load(doc, it, true) }
    }

    enum class Script { LATIN, DEVANAGARI, TELUGU }

    companion object {
        fun dominantScript(text: String): Script {
            var deva = 0
            var telugu = 0
            text.codePoints().forEach { cp ->
                when (cp) {
                    in 0x0900..0x097F, in 0xA8E0..0xA8FF -> deva++
                    in 0x0C00..0x0C7F -> telugu++
                }
            }
            return when {
                deva == 0 && telugu == 0 -> Script.LATIN
                deva >= telugu -> Script.DEVANAGARI
                else -> Script.TELUGU
            }
        }

        /**
         * Replaces characters the font cannot encode with '?', and strips
         * control characters, so content-stream writes never throw.
         */
        fun sanitize(font: PDFont, text: String): String {
            val sb = StringBuilder(text.length)
            var i = 0
            while (i < text.length) {
                val cp = text.codePointAt(i)
                val chars = String(Character.toChars(cp))
                i += chars.length
                if (Character.isISOControl(cp)) continue
                val ok = try {
                    font.encode(chars)
                    true
                } catch (e: Exception) {
                    false
                }
                sb.append(if (ok) chars else "?")
            }
            return sb.toString()
        }

        fun width(font: PDFont, text: String, size: Float): Float =
            try {
                font.getStringWidth(text) / 1000f * size
            } catch (e: Exception) {
                text.length * size * 0.5f
            }
    }
}
