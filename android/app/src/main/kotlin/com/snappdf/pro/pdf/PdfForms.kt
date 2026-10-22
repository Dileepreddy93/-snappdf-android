package com.snappdf.pro.pdf

import com.snappdf.pro.OpError
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDCheckBox
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDChoice
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDComboBox
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDField
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDListBox
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDPushButton
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDRadioButton
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDSignatureField
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDTerminalField
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDTextField

object PdfForms {

    private fun typeOf(field: PDField): String = when (field) {
        is PDTextField -> "text"
        is PDCheckBox -> "checkbox"
        is PDRadioButton -> "radio"
        is PDComboBox -> "combo"
        is PDListBox -> "list"
        is PDSignatureField -> "signature"
        is PDPushButton -> "button"
        else -> "unknown"
    }

    fun listFields(path: String, password: String?): Map<String, Any?> = PdfDocs.use(path, password) { doc ->
        val form = doc.documentCatalog.acroForm
        if (form == null) return@use mapOf("fields" to emptyList<Any>(), "xfa" to false)
        val dynamicXfa = form.xfaIsDynamic()
        val pageIndex = HashMap<Any, Int>()
        doc.pages.forEachIndexed { i, p -> pageIndex[p.cosObject] = i }
        val fields = form.fieldTree.filterIsInstance<PDTerminalField>().mapNotNull { field ->
            val type = typeOf(field)
            if (type == "button" || type == "unknown") return@mapNotNull null
            val widget = field.widgets.firstOrNull()
            val page = widget?.page?.let { pageIndex[it.cosObject] }
                ?: doc.pages.indexOfFirst { p -> p.annotations.any { it.cosObject === widget?.cosObject } }.takeIf { it >= 0 }
            val options: List<String> = when (field) {
                is PDChoice -> field.optionsDisplayValues
                is PDRadioButton -> field.exportValues.ifEmpty { field.onValues.toList() }
                is PDCheckBox -> listOf(field.onValue)
                else -> emptyList()
            }
            val value: Any? = when (field) {
                is PDCheckBox -> field.isChecked
                is PDListBox -> field.value
                is PDChoice -> field.value.firstOrNull()
                is PDSignatureField -> null
                else -> field.valueAsString
            }
            mapOf(
                "name" to field.fullyQualifiedName,
                "label" to (field.alternateFieldName ?: field.partialName),
                "type" to type,
                "value" to value,
                "options" to options,
                "readOnly" to field.isReadOnly,
                "required" to field.isRequired,
                "multiline" to ((field as? PDTextField)?.isMultiline ?: false),
                "maxLength" to ((field as? PDTextField)?.maxLen?.takeIf { it > 0 }),
                "multiSelect" to ((field as? PDListBox)?.isMultiSelect ?: false),
                "page" to page,
            )
        }
        mapOf("fields" to fields, "xfa" to dynamicXfa)
    }

    /**
     * Sets field values by fully qualified name. Values: String for text,
     * combo and radio; Boolean for checkboxes; List<String> for list boxes.
     */
    fun fill(path: String, password: String?, output: String, values: Map<String, Any?>, flatten: Boolean) {
        PdfDocs.use(path, password) { doc ->
            PdfDocs.requireModifyPermission(doc)
            val form = doc.documentCatalog.acroForm ?: throw OpError(OpError.UNSUPPORTED, "This PDF has no fillable form fields.")
            if (form.xfaIsDynamic()) {
                throw OpError(OpError.UNSUPPORTED, "This is a dynamic XFA form, which cannot be filled on this device.")
            }
            // Static XFA forms have an AcroForm equivalent; drop the XFA copy so
            // viewers display the AcroForm values we write.
            if (form.hasXFA()) form.xfa = null
            for ((name, value) in values) {
                val field = form.getField(name) ?: throw OpError.badArgs("Unknown field: $name")
                if (field.isReadOnly) continue
                try {
                    when (field) {
                        is PDCheckBox -> if (value == true || value == "true") field.check() else field.unCheck()
                        is PDRadioButton -> (value as? String)?.let { field.value = it }
                        is PDListBox -> {
                            @Suppress("UNCHECKED_CAST")
                            val list = (value as? List<String>) ?: listOfNotNull(value as? String)
                            field.setValue(list)
                        }
                        is PDChoice -> field.setValue(value?.toString() ?: "")
                        is PDTextField -> {
                            val text = value?.toString() ?: ""
                            val max = field.maxLen
                            field.value = if (max > 0 && text.length > max) text.substring(0, max) else text
                        }
                        else -> {}
                    }
                } catch (e: IllegalArgumentException) {
                    throw OpError(
                        OpError.UNSUPPORTED,
                        "The field \"${field.partialName}\" cannot display some of the entered characters (its font does not include them).",
                        e,
                    )
                }
            }
            if (flatten) {
                form.refreshAppearances()
                form.flatten()
            } else {
                form.needAppearances = false
            }
            PdfDocs.save(doc, output)
        }
    }
}
