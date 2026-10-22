package com.snappdf.pro.io

import android.app.Activity
import android.content.Context
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import androidx.print.PrintHelper
import com.snappdf.pro.OpError
import com.snappdf.pro.ml.Ocr
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/** Sends PDFs and images to the Android print framework. */
object PrintIo {

    fun print(activity: Activity, path: String, jobName: String) {
        val file = File(path)
        if (!file.isFile) throw OpError(OpError.IO, "File not found.")
        val manager = activity.getSystemService(Context.PRINT_SERVICE) as PrintManager
        if (path.lowercase().endsWith(".pdf")) {
            manager.print(jobName, PdfFileAdapter(file, jobName), PrintAttributes.Builder().build())
        } else {
            val bitmap = Ocr.decodeUpright(path, 3000)
            PrintHelper(activity).apply { scaleMode = PrintHelper.SCALE_MODE_FIT }.printBitmap(jobName, bitmap)
        }
    }

    private class PdfFileAdapter(private val file: File, private val name: String) : PrintDocumentAdapter() {
        override fun onLayout(
            oldAttributes: PrintAttributes?, newAttributes: PrintAttributes?, cancellationSignal: CancellationSignal?,
            callback: LayoutResultCallback, extras: Bundle?,
        ) {
            if (cancellationSignal?.isCanceled == true) {
                callback.onLayoutCancelled()
                return
            }
            val info = PrintDocumentInfo.Builder(name)
                .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                .build()
            callback.onLayoutFinished(info, oldAttributes != newAttributes)
        }

        override fun onWrite(
            pages: Array<out PageRange>?, destination: ParcelFileDescriptor, cancellationSignal: CancellationSignal?,
            callback: WriteResultCallback,
        ) {
            try {
                FileInputStream(file).use { input ->
                    FileOutputStream(destination.fileDescriptor).use { output -> input.copyTo(output) }
                }
                callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
            } catch (e: Exception) {
                callback.onWriteFailed(e.message)
            }
        }
    }
}
