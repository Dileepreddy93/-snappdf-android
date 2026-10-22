package com.snappdf.pro.bridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.FileProvider
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.snappdf.pro.OpContext
import com.snappdf.pro.OpError
import com.snappdf.pro.io.FileIo
import com.snappdf.pro.io.PrintIo
import com.snappdf.pro.io.SecureStore
import com.snappdf.pro.ml.Ocr
import com.snappdf.pro.ml.Segmenter
import com.snappdf.pro.pdf.PageRef
import com.snappdf.pro.pdf.PdfCompress
import com.snappdf.pro.pdf.PdfCreate
import com.snappdf.pro.pdf.PdfDocs
import com.snappdf.pro.pdf.PdfEdit
import com.snappdf.pro.pdf.PdfEdits
import com.snappdf.pro.pdf.PdfForms
import com.snappdf.pro.pdf.PdfPages
import com.snappdf.pro.pdf.PdfRaster
import com.snappdf.pro.pdf.PdfRedact
import com.snappdf.pro.pdf.PdfSecurity
import com.snappdf.pro.pdf.PdfStamp
import com.snappdf.pro.pdf.SourceDoc
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * The single method channel between Flutter and native processing.
 * Long-running work runs on Dispatchers.IO, at most two heavy jobs at a time.
 */
class NativeBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val context = activity.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val heavy = Semaphore(2)
    private val jobs = ConcurrentHashMap<String, Job>()
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "com.snappdf.pro/native")
    private var progressSink: EventChannel.EventSink? = null
    private val pending = ConcurrentHashMap<Int, CompletableDeferred<Pair<Int, Intent?>>>()
    private var nextRequest = 7100
    private val incoming = ArrayList<Map<String, Any?>>()
    private val secure by lazy { SecureStore(context) }
    private val tempDir: File get() = File(context.cacheDir, "work").apply { mkdirs() }

    init {
        PDFBoxResourceLoader.init(context)
        PdfDocs.tempDir = File(context.cacheDir, "pdfbox")
        channel.setMethodCallHandler { call, result -> dispatch(call, result) }
        EventChannel(messenger, "com.snappdf.pro/progress").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
        scope.launch(Dispatchers.IO) { runCatching { FileIo.cleanStale(context) } }
    }

    fun dispose() {
        scope.cancel()
        channel.setMethodCallHandler(null)
    }

    // ---- Activity results ----

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val deferred = pending.remove(requestCode) ?: return false
        deferred.complete(resultCode to data)
        return true
    }

    private suspend fun launchForResult(intent: Intent): Pair<Int, Intent?> {
        val code = synchronized(this) { nextRequest++ }
        val deferred = CompletableDeferred<Pair<Int, Intent?>>()
        pending[code] = deferred
        try {
            activity.startActivityForResult(intent, code)
        } catch (e: android.content.ActivityNotFoundException) {
            pending.remove(code)
            throw OpError(OpError.UNAVAILABLE, "No app on this device can handle this action.")
        }
        return deferred.await()
    }

    // ---- Incoming "open with" / "share to" intents ----

    fun handleIntent(intent: Intent?) {
        intent ?: return
        val uris = ArrayList<Uri>()
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.let { uris.add(it) }
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
            }
        }
        if (uris.isEmpty()) return
        scope.launch {
            val imported = withContext(Dispatchers.IO) {
                uris.mapNotNull { uri -> runCatching { FileIo.importUri(context, uri) }.getOrNull() }
            }
            synchronized(incoming) { incoming.addAll(imported) }
            channel.invokeMethod("incomingAvailable", null)
        }
    }

    // ---- Dispatch ----

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        val args = Args(call)
        val jobId = args.stringOrNull("jobId") ?: UUID.randomUUID().toString()
        val job = scope.launch {
            try {
                val value = handle(call.method, args, jobId)
                result.success(value)
            } catch (e: OpError) {
                result.error(e.code, e.message, null)
            } catch (e: CancellationException) {
                result.error(OpError.CANCELLED, "Cancelled.", null)
            } catch (e: NotImplementedError) {
                result.notImplemented()
            } catch (e: OutOfMemoryError) {
                result.error(OpError.OUT_OF_MEMORY, "Not enough memory to complete this operation.", null)
            } catch (e: Throwable) {
                result.error(OpError.INTERNAL, e.message ?: e.javaClass.simpleName, e.stackTraceToString().take(2000))
            } finally {
                jobs.remove(jobId)
            }
        }
        jobs[jobId] = job
    }

    private fun opContext(jobId: String): OpContext = object : OpContext {
        private var lastSent = 0L
        override fun checkCancelled() {
            val job = jobs[jobId]
            if (job != null && !job.isActive) throw OpError(OpError.CANCELLED, "Cancelled.")
        }

        override fun progress(done: Int, total: Int, message: String?) {
            val now = SystemClock.elapsedRealtime()
            if (done < total && now - lastSent < 80) return
            lastSent = now
            val event = mapOf("jobId" to jobId, "done" to done, "total" to total, "message" to message)
            main.post { progressSink?.success(event) }
        }
    }

    /** Runs heavy work off the main thread with the concurrency limit. */
    private suspend fun <T> work(block: () -> T): T = heavy.withPermit { withContext(Dispatchers.IO) { block() } }

    private suspend fun handle(method: String, a: Args, jobId: String): Any? {
        val ctx = opContext(jobId)
        return when (method) {
            "job.cancel" -> {
                jobs[a.string("target")]?.cancel()
                true
            }
            "app.takeIncoming" -> synchronized(incoming) { ArrayList(incoming).also { incoming.clear() } }
            "app.cleanTemp" -> withContext(Dispatchers.IO) {
                FileIo.cleanStale(context, a.long("maxAgeMs", 0L))
                true
            }

            // -- Files --
            "io.pickFiles" -> pickFiles(a.strings("mimeTypes"), a.bool("multiple"))
            "io.saveAs" -> saveAs(File(a.string("path")), a.string("name"), a.string("mime"))
            "io.pickFolder" -> pickFolder()
            "io.exportToFolder" -> work {
                val files = a.objects("files").map { File(it.string("path")) to FileIo.safeName(it.string("name")) }
                FileIo.exportToTree(context, Uri.parse(a.string("treeUri")), files)
            }
            "io.share" -> share(a.strings("paths"), a.string("mime"), a.stringOrNull("title"))
            "io.print" -> {
                PrintIo.print(activity, a.string("path"), a.string("name"))
                true
            }
            "io.camera" -> camera()
            "io.scan" -> scan(a.int("pageLimit", 20), a.bool("allowGallery", true))
            "io.scannerAvailable" -> scannerAvailable()

            // -- Secure storage --
            "secure.write" -> work { secure.write(a.string("name"), a.bytes("data")); true }
            "secure.read" -> work { secure.read(a.string("name")) }
            "secure.delete" -> work { secure.delete(a.string("name")) }
            "secure.list" -> work { secure.list() }

            // -- PDF --
            "pdf.info" -> work { PdfPages.info(a.string("path"), a.stringOrNull("password")) }
            "pdf.merge" -> work {
                PdfPages.merge(sources(a), a.string("output"), ctx)
                a.string("output")
            }
            "pdf.assemble" -> work {
                val pages = a.objects("pages").map {
                    PageRef(
                        source = it.int("source", 0), pageIndex = it.int("page", 0), rotate = it.int("rotate", 0),
                        blankWidth = it.doubleOrNull("blankWidth")?.toFloat(), blankHeight = it.doubleOrNull("blankHeight")?.toFloat(),
                        crop = it.doubles("crop"),
                    )
                }
                PdfPages.assemble(sources(a), pages, a.string("output"), ctx)
                a.string("output")
            }
            "pdf.extractText" -> work { PdfPages.extractText(a.string("path"), a.stringOrNull("password"), a.ints("pages"), ctx) }
            "pdf.watermark" -> work {
                PdfStamp.watermark(
                    context, a.string("path"), a.stringOrNull("password"), a.string("output"),
                    PdfStamp.Watermark(
                        text = a.stringOrNull("text"), imagePath = a.stringOrNull("imagePath"),
                        fontSize = a.float("fontSize", 48f), color = a.long("color", 0xFF888888), opacity = a.float("opacity", 0.3f),
                        rotation = a.double("rotation", -45.0), layout = a.stringOrNull("layout") ?: "center",
                        imageScale = a.double("imageScale", 0.4), pages = a.ints("pages"),
                    ),
                    ctx,
                )
                a.string("output")
            }
            "pdf.pageNumbers" -> work {
                PdfStamp.pageNumbers(
                    context, a.string("path"), a.stringOrNull("password"), a.string("output"),
                    PdfStamp.PageNumbers(
                        format = a.stringOrNull("format") ?: "", position = a.stringOrNull("position") ?: "bottom-center",
                        fontSize = a.float("fontSize", 10f), color = a.long("color", 0xFF333333), margin = a.double("margin", 28.0),
                        startAt = a.int("startAt", 1), skipFirst = a.bool("skipFirst"),
                        header = a.stringOrNull("header"), footer = a.stringOrNull("footer"), pages = a.ints("pages"),
                    ),
                    ctx,
                )
                a.string("output")
            }
            "pdf.protect" -> work {
                val p = a.objOrNull("permissions")
                PdfSecurity.protect(
                    a.string("path"), a.stringOrNull("password"), a.string("output"),
                    a.string("userPassword"), a.stringOrNull("ownerPassword"),
                    PdfSecurity.Permissions(
                        print = p?.bool("print", true) ?: true, copy = p?.bool("copy", true) ?: true,
                        modify = p?.bool("modify", true) ?: true, annotate = p?.bool("annotate", true) ?: true,
                        fillForms = p?.bool("fillForms", true) ?: true,
                    ),
                )
                a.string("output")
            }
            "pdf.unlock" -> work {
                PdfSecurity.unlock(a.string("path"), a.stringOrNull("password"), a.string("output"))
                a.string("output")
            }
            "pdf.setMetadata" -> work {
                val m = a.objOrNull("metadata")
                PdfSecurity.setMetadata(
                    a.string("path"), a.stringOrNull("password"), a.string("output"),
                    m?.let {
                        PdfSecurity.Metadata(
                            it.stringOrNull("title"), it.stringOrNull("author"), it.stringOrNull("subject"),
                            it.stringOrNull("keywords"), it.stringOrNull("creator"), it.stringOrNull("producer"),
                        )
                    },
                    a.bool("removeAll"),
                )
                a.string("output")
            }
            "pdf.compress" -> work {
                val r = PdfCompress.compress(
                    a.string("path"), a.stringOrNull("password"), a.string("output"),
                    PdfCompress.Options(
                        maxDpi = a.int("maxDpi", 150), jpegQuality = a.float("jpegQuality", 0.7f),
                        stripMetadata = a.bool("stripMetadata", true), grayscale = a.bool("grayscale"),
                    ),
                    ctx,
                )
                mapOf(
                    "inputBytes" to r.inputBytes, "outputBytes" to r.outputBytes,
                    "imagesRecompressed" to r.imagesRecompressed, "imagesKept" to r.imagesKept, "pageCount" to r.pageCount,
                )
            }
            "pdf.toImages" -> work {
                PdfRaster.toImages(
                    a.string("path"), a.stringOrNull("password"), a.ints("pages"), a.float("dpi", 150f),
                    a.stringOrNull("format") ?: "jpg", a.int("quality", 90), a.string("outDir"), a.string("baseName"), tempDir, ctx,
                )
            }
            "pdf.renderPage" -> work {
                PdfRaster.renderToFile(a.string("path"), a.stringOrNull("password"), a.int("page"), a.int("maxWidth", 1080), a.string("output"), tempDir)
            }
            "pdf.imagesToPdf" -> work {
                PdfCreate.imagesToPdf(
                    a.strings("images"), a.string("output"),
                    PdfCreate.ImagePdfOptions(
                        pageSize = a.stringOrNull("pageSize") ?: "a4", orientation = a.stringOrNull("orientation") ?: "auto",
                        margin = a.float("margin", 0f), quality = a.stringOrNull("quality") ?: "original",
                        dpi = a.float("dpi", 300f),
                    ),
                    ctx,
                )
                a.string("output")
            }
            "pdf.textToPdf" -> work {
                PdfCreate.textToPdf(
                    context, a.string("text"), a.string("output"),
                    PdfCreate.TextPdfOptions(
                        fontSize = a.float("fontSize", 11f), margin = a.float("margin", 56f), pageSize = a.stringOrNull("pageSize") ?: "a4",
                    ),
                    ctx,
                )
                a.string("output")
            }
            "pdf.redact" -> work {
                val regions = a.objects("regions").map { r ->
                    PdfRedact.PageRedaction(r.int("page"), (r.raw("rects") as? List<*>)?.map { rect ->
                        (rect as? List<*>)?.map { (it as Number).toDouble() } ?: throw OpError.badArgs("Bad rect.")
                    } ?: emptyList())
                }
                val r = PdfRedact.redact(
                    a.string("path"), a.stringOrNull("password"), a.string("output"), regions,
                    a.float("dpi", 200f), a.bool("stripMetadata", true), tempDir, ctx,
                )
                mapOf("pagesRedacted" to r.pagesRedacted, "verified" to r.verifiedTextFree)
            }
            "pdf.applyEdits" -> work {
                PdfEdits.apply(
                    context, a.string("path"), a.stringOrNull("password"), a.string("output"),
                    a.objects("edits").map { parseEdit(it) }, a.bool("flatten"), a.stringOrNull("author"), ctx,
                )
                a.string("output")
            }
            "pdf.flatten" -> work { PdfEdits.flattenDocument(a.string("path"), a.stringOrNull("password"), a.string("output"), ctx) }
            "pdf.formFields" -> work { PdfForms.listFields(a.string("path"), a.stringOrNull("password")) }
            "pdf.fillForm" -> work {
                @Suppress("UNCHECKED_CAST")
                val values = (a.raw("values") as? Map<String, Any?>) ?: emptyMap()
                PdfForms.fill(a.string("path"), a.stringOrNull("password"), a.string("output"), values, a.bool("flatten"))
                a.string("output")
            }

            // -- OCR / ML --
            "ocr.recognize" -> work { Ocr.recognizeFile(a.string("path"), a.stringOrNull("script") ?: "latin") }
            "ocr.imagesToPdf" -> work {
                val r = Ocr.imagesToSearchablePdf(
                    context, a.strings("images"), a.string("output"), a.stringOrNull("script") ?: "latin",
                    a.stringOrNull("pageSize") ?: "a4", ctx,
                )
                mapOf("pages" to r.pages, "lines" to r.linesRecognized, "text" to r.text)
            }
            "ocr.pdf" -> work {
                val r = Ocr.ocrPdf(
                    context, a.string("path"), a.stringOrNull("password"), a.string("output"),
                    a.stringOrNull("script") ?: "latin", a.bool("force"), tempDir, ctx,
                )
                mapOf("pages" to r.pages, "lines" to r.linesRecognized, "text" to r.text)
            }
            "ml.personMask" -> work { Segmenter.personMask(a.string("path"), a.string("output")) }
            else -> throw NotImplementedError(method)
        }
    }

    private fun sources(a: Args) = a.objects("sources").map { SourceDoc(it.string("path"), it.stringOrNull("password")) }

    private fun parseEdit(e: Args): PdfEdit {
        val page = e.int("page")
        return when (val type = e.string("type")) {
            "text" -> PdfEdit.Text(
                page, e.double("x"), e.double("y"), e.string("text"), e.float("fontSize", 14f),
                e.long("color", 0xFF000000), e.bool("bold"), e.double("rotation", 0.0),
                e.doubleOrNull("baseline"), e.doubleOrNull("lineHeight"),
            )
            "image" -> PdfEdit.Image(
                page, e.double("x"), e.double("y"), e.double("w"), e.double("h"), e.string("path"),
                e.double("rotation", 0.0), e.float("opacity", 1f),
            )
            "ink" -> PdfEdit.Ink(
                page, (e.raw("strokes") as? List<*>)?.map { s -> (s as List<*>).map { (it as Number).toDouble() } } ?: emptyList(),
                e.long("color", 0xFF1A73E8), e.float("width", 2f), e.float("opacity", 1f),
            )
            "highlight", "underline", "strikeout" -> PdfEdit.Markup(
                page, type, e.doubles("rect") ?: throw OpError.badArgs("Missing rect."), e.long("color", 0xFFFFEB3B),
            )
            "note" -> PdfEdit.Note(page, e.double("x"), e.double("y"), e.string("text"), e.long("color", 0xFFF9A825))
            "stamp" -> PdfEdit.Stamp(
                page, e.double("x"), e.double("y"), e.double("w"), e.double("h"), e.string("text"), e.long("color", 0xFFC62828),
            )
            else -> throw OpError.badArgs("Unknown edit type '$type'.")
        }
    }

    // ---- Activity-backed actions ----

    private suspend fun pickFiles(mimeTypes: List<String>, multiple: Boolean): List<Map<String, Any?>> {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (mimeTypes.size == 1) mimeTypes[0] else "*/*"
            if (mimeTypes.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
        }
        val (code, data) = launchForResult(intent)
        if (code != Activity.RESULT_OK || data == null) return emptyList()
        val uris = ArrayList<Uri>()
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri) }
        if (uris.isEmpty()) data.data?.let { uris.add(it) }
        return work { uris.map { FileIo.importUri(context, it) } }
    }

    private suspend fun saveAs(file: File, name: String, mime: String): String? {
        if (!file.isFile) throw OpError(OpError.IO, "File not found.")
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, FileIo.safeName(name))
        }
        val (code, data) = launchForResult(intent)
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) return null
        work { FileIo.copyToUri(context, file, uri) }
        return uri.toString()
    }

    private suspend fun pickFolder(): Map<String, Any?>? {
        val (code, data) = launchForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE))
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) return null
        runCatching {
            context.contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
        val name = androidx.documentfile.provider.DocumentFile.fromTreeUri(context, uri)?.name
        return mapOf("uri" to uri.toString(), "name" to name)
    }

    private suspend fun share(paths: List<String>, mime: String, title: String?): Boolean {
        val uris = work {
            val dir = File(context.cacheDir, "share/${UUID.randomUUID()}").apply { mkdirs() }
            paths.map { p ->
                val src = File(p)
                if (!src.isFile) throw OpError(OpError.IO, "File not found.")
                val copy = File(dir, FileIo.safeName(src.name))
                src.copyTo(copy, overwrite = true)
                FileProvider.getUriForFile(context, "${context.packageName}.files", copy)
            }
        }
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).apply { putExtra(Intent.EXTRA_STREAM, uris[0]) }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply { putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris)) }
        }
        intent.type = mime
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        intent.clipData = android.content.ClipData.newRawUri(null, uris[0]).apply {
            uris.drop(1).forEach { addItem(android.content.ClipData.Item(it)) }
        }
        activity.startActivity(Intent.createChooser(intent, title ?: "Share"))
        return true
    }

    private suspend fun camera(): String? {
        val dir = File(context.cacheDir, "camera").apply { mkdirs() }
        val file = File(dir, "photo_${System.currentTimeMillis()}.jpg")
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        val intent = Intent(android.provider.MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(android.provider.MediaStore.EXTRA_OUTPUT, uri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val (code, _) = launchForResult(intent)
        if (code != Activity.RESULT_OK || !file.isFile || file.length() == 0L) {
            file.delete()
            return null
        }
        return file.path
    }

    private suspend fun scannerAvailable(): Boolean {
        val client = GmsDocumentScanning.getClient(GmsDocumentScannerOptions.Builder().build())
        val deferred = CompletableDeferred<Boolean>()
        ModuleInstall.getClient(context).areModulesAvailable(client)
            .addOnSuccessListener { deferred.complete(it.areModulesAvailable()) }
            .addOnFailureListener { deferred.complete(false) }
        return deferred.await()
    }

    private suspend fun scan(pageLimit: Int, allowGallery: Boolean): List<String> {
        val options = GmsDocumentScannerOptions.Builder()
            .setGalleryImportAllowed(allowGallery)
            .setPageLimit(pageLimit.coerceIn(1, 100))
            .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
            .build()
        val senderDeferred = CompletableDeferred<android.content.IntentSender>()
        GmsDocumentScanning.getClient(options).getStartScanIntent(activity)
            .addOnSuccessListener { senderDeferred.complete(it) }
            .addOnFailureListener {
                senderDeferred.completeExceptionally(
                    OpError(OpError.UNAVAILABLE, "The document scanner is not available on this device: ${it.message}"),
                )
            }
        val sender = senderDeferred.await()
        val code = synchronized(this) { nextRequest++ }
        val deferred = CompletableDeferred<Pair<Int, Intent?>>()
        pending[code] = deferred
        activity.startIntentSenderForResult(sender, code, null, 0, 0, 0)
        val (resultCode, data) = deferred.await()
        if (resultCode != Activity.RESULT_OK || data == null) return emptyList()
        val result = GmsDocumentScanningResult.fromActivityResultIntent(data) ?: return emptyList()
        return work {
            result.pages?.map { page -> FileIo.importUri(context, page.imageUri)["path"] as String } ?: emptyList()
        }
    }
}
