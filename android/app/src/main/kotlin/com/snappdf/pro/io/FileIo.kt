package com.snappdf.pro.io

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import com.snappdf.pro.OpError
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.UUID

/** Copies between content URIs (Storage Access Framework) and app-private files. */
object FileIo {
    /** Per-file import limit. */
    const val MAX_IMPORT_BYTES: Long = 512L * 1024 * 1024

    fun importDir(context: Context) = File(context.cacheDir, "import")

    /** Removes characters that are invalid in file names on Android providers. */
    fun safeName(name: String?, fallback: String = "file"): String {
        val cleaned = (name ?: "").replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001F]"), "_").trim().trim('.')
        return cleaned.take(120).ifEmpty { fallback }
    }

    /**
     * Copies [uri] into a fresh private directory and returns its metadata.
     * The original document is never modified.
     */
    fun importUri(context: Context, uri: Uri): Map<String, Any?> {
        val resolver = context.contentResolver
        var name: String? = null
        var size: Long = -1
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (ni >= 0) name = c.getString(ni)
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                }
            }
        } catch (e: Exception) {
            // Some providers do not support queries; fall back to the URI path.
        }
        if (name == null && uri.scheme == "file") name = uri.lastPathSegment
        val mime = resolver.getType(uri) ?: guessMime(name)
        if (size > MAX_IMPORT_BYTES) {
            throw OpError(OpError.TOO_LARGE, "${name ?: "This file"} is larger than ${MAX_IMPORT_BYTES / (1024 * 1024)} MB.")
        }
        var fileName = safeName(name, "import")
        if (!fileName.contains('.')) {
            MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)?.let { fileName = "$fileName.$it" }
        }
        val dir = File(importDir(context), UUID.randomUUID().toString()).apply { mkdirs() }
        val out = File(dir, fileName)
        try {
            val input = resolver.openInputStream(uri) ?: throw OpError(OpError.IO, "Cannot open the selected file.")
            input.use { inp ->
                out.outputStream().use { o ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val n = inp.read(buffer)
                        if (n < 0) break
                        total += n
                        if (total > MAX_IMPORT_BYTES) throw OpError(OpError.TOO_LARGE, "The file is too large to import.")
                        o.write(buffer, 0, n)
                    }
                }
            }
        } catch (e: OpError) {
            dir.deleteRecursively()
            throw e
        } catch (e: SecurityException) {
            dir.deleteRecursively()
            throw OpError(OpError.IO, "Permission to read the file was denied.", e)
        } catch (e: IOException) {
            dir.deleteRecursively()
            throw OpError(OpError.IO, "Could not read the selected file: ${e.message}", e)
        }
        return mapOf("path" to out.path, "name" to fileName, "size" to out.length(), "mime" to mime)
    }

    fun guessMime(name: String?): String {
        val ext = name?.substringAfterLast('.', "")?.lowercase() ?: ""
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    fun copyToUri(context: Context, source: File, target: Uri) {
        try {
            val out = context.contentResolver.openOutputStream(target, "wt")
                ?: throw OpError(OpError.IO, "Cannot write to the chosen location.")
            out.use { o -> FileInputStream(source).use { it.copyTo(o, 64 * 1024) } }
        } catch (e: SecurityException) {
            throw OpError(OpError.IO, "Permission to write was denied.", e)
        } catch (e: IOException) {
            throw OpError(OpError.IO, "Could not save the file: ${e.message}", e)
        }
    }

    /** Writes files into a user-chosen folder; returns the names actually used. */
    fun exportToTree(context: Context, treeUri: Uri, files: List<Pair<File, String>>): List<String> {
        val tree = DocumentFile.fromTreeUri(context, treeUri)
            ?: throw OpError(OpError.IO, "The chosen folder is not available.")
        if (!tree.canWrite()) throw OpError(OpError.IO, "SnapPDF cannot write to the chosen folder. Choose it again.")
        return files.map { (file, displayName) ->
            val mime = guessMime(displayName)
            val created = tree.createFile(mime, displayName)
                ?: throw OpError(OpError.IO, "Could not create $displayName in the chosen folder.")
            copyToUri(context, file, created.uri)
            created.name ?: displayName
        }
    }

    /** Deletes stale temporary files left by interrupted operations. */
    fun cleanStale(context: Context, maxAgeMs: Long = 24L * 3600 * 1000) {
        val now = System.currentTimeMillis()
        listOf("import", "share", "camera", "work", "pdfbox", "render").forEach { name ->
            File(context.cacheDir, name).listFiles()?.forEach { f ->
                if (now - f.lastModified() > maxAgeMs) f.deleteRecursively()
            }
        }
    }
}
