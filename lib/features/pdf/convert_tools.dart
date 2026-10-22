import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import '../../core/util/page_ranges.dart';
import 'pdf_common.dart';

class ImagesToPdfScreen extends ConsumerStatefulWidget {
  const ImagesToPdfScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<ImagesToPdfScreen> createState() => _ImagesToPdfScreenState();
}

class _ImagesToPdfScreenState extends ConsumerState<ImagesToPdfScreen> {
  late List<InputFile> _images = widget.initial.where((f) => f.kind == FileKind.image).toList();
  String _pageSize = 'a4';
  String _orientation = 'auto';
  String _quality = 'original';
  bool _margin = false;
  final _name = TextEditingController(text: 'Images.pdf');

  @override
  Widget build(BuildContext context) {
    final api = ref.read(nativeApiProvider);
    return ToolScaffold(
      title: 'Images to PDF',
      about:
          'Creates a PDF with one image per page, in the order shown. With “Original” quality, '
          'JPEG photos are embedded without recompression, so no detail is lost. Photo orientation '
          'from the camera is respected.',
      actionLabel: _images.isEmpty ? 'Create PDF' : 'Create PDF (${pages(_images.length)})',
      actionIcon: Icons.picture_as_pdf_outlined,
      canRun: () => _images.isEmpty ? 'Add at least one image' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InputsCard(
            inputs: _images,
            accept: Accept.image,
            multiple: true,
            reorderable: true,
            emptyLabel: 'Add images',
            onChanged: (l) => setState(() => _images = l),
          ),
          const SizedBox(height: Gaps.xl),
          OptionGroup(
            title: 'Page size',
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'a4', label: Text('A4')),
                  ButtonSegment(value: 'letter', label: Text('Letter')),
                  ButtonSegment(value: 'fit', label: Text('Fit image')),
                ],
                selected: {_pageSize},
                onSelectionChanged: (v) => setState(() => _pageSize = v.first),
              ),
              if (_pageSize != 'fit') ...[
                const SizedBox(height: Gaps.m),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'auto', label: Text('Auto')),
                    ButtonSegment(value: 'portrait', label: Text('Portrait')),
                    ButtonSegment(value: 'landscape', label: Text('Landscape')),
                  ],
                  selected: {_orientation},
                  onSelectionChanged: (v) => setState(() => _orientation = v.first),
                ),
              ],
            ],
          ),
          OptionGroup(
            title: 'Image quality',
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'original', label: Text('Original')),
                  ButtonSegment(value: 'high', label: Text('High')),
                  ButtonSegment(value: 'medium', label: Text('Smaller')),
                ],
                selected: {_quality},
                onSelectionChanged: (v) => setState(() => _quality = v.first),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _margin,
            onChanged: (v) => setState(() => _margin = v),
            title: const Text('Add margins'),
          ),
          const SizedBox(height: Gaps.m),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'File name'),
          ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        var name = sanitizeFileName(_name.text.trim().isEmpty ? 'Images' : _name.text.trim());
        if (!name.toLowerCase().endsWith('.pdf')) name = '$name.pdf';
        final out = await ws.newWorkFile(name);
        await api.imagesToPdf(
          [for (final i in _images) i.path],
          out,
          pageSize: _pageSize,
          orientation: _orientation,
          quality: _quality,
          margin: _margin ? 24 : 0,
          jobId: job.id,
        );
        return ToolResult(
          headline: 'Created a PDF with ${pages(_images.length)}',
          outputs: [OutputFile(out, name)],
          checks: await verifyPdf(api, out, expectedPages: _images.length),
        );
      },
    );
  }
}

class PdfToImagesScreen extends ConsumerStatefulWidget {
  const PdfToImagesScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<PdfToImagesScreen> createState() => _PdfToImagesScreenState();
}

class _PdfToImagesScreenState extends ConsumerState<PdfToImagesScreen> with PdfInputs {
  String _format = 'jpg';
  double _dpi = 150;
  final _pages = TextEditingController();
  String? _pagesError;

  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  List<int>? get _selection {
    final count = firstInfo?.pageCount ?? 0;
    if (_pages.text.trim().isEmpty) return null;
    try {
      return parsePageSelection(_pages.text, count);
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = firstInfo?.pageCount ?? 0;
    final n = _selection?.length ?? count;
    return ToolScaffold(
      title: 'PDF to images',
      about: 'Saves each page as a JPG or PNG image. Higher resolution gives sharper images and larger files.',
      actionLabel: n > 0 ? 'Export ${n == 1 ? '1 image' : '$n images'}' : 'Export',
      actionIcon: Icons.image_outlined,
      canRun: () {
        if (first == null) return 'Choose a PDF';
        if (_pagesError != null) return 'Fix the page selection';
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(),
          const SizedBox(height: Gaps.xl),
          OptionGroup(
            title: 'Format',
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'jpg', label: Text('JPG')),
                  ButtonSegment(value: 'png', label: Text('PNG')),
                ],
                selected: {_format},
                onSelectionChanged: (v) => setState(() => _format = v.first),
              ),
            ],
          ),
          LabeledSlider(
            label: 'Resolution',
            value: _dpi,
            min: 72,
            max: 300,
            divisions: 19,
            format: (v) => '${v.round()} dpi',
            onChanged: (v) => setState(() => _dpi = v),
          ),
          const SizedBox(height: Gaps.m),
          PageRangeField(
            controller: _pages,
            label: 'Pages (leave empty for all)',
            error: _pagesError,
            onChanged: (v) {
              String? err;
              if (v.trim().isNotEmpty && count > 0) {
                try {
                  parsePageRanges(v, count);
                } on FormatException catch (e) {
                  err = e.message;
                }
              }
              setState(() => _pagesError = err);
            },
          ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final f = first!;
        final dir = await ws.newWorkDir();
        final base = p.basenameWithoutExtension(f.name);
        final paths = await withOwnerPassword(
          this,
          f,
          () => api.pdfToImages(
            f.path,
            f.password,
            pages: _selection,
            dpi: _dpi,
            format: _format,
            outDir: dir.path,
            baseName: 'page',
            jobId: job.id,
          ),
        );
        final outputs = [
          for (final path in paths)
            OutputFile(path, sanitizeFileName('${base}_${p.basename(path).replaceFirst('page_', '')}')),
        ];
        return ToolResult(
          headline: 'Exported ${outputs.length} image${outputs.length == 1 ? '' : 's'}',
          outputs: outputs,
          checks: [Check('${outputs.length} of $n pages exported', outputs.length == n)],
        );
      },
    );
  }
}

class TextToPdfScreen extends ConsumerStatefulWidget {
  const TextToPdfScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<TextToPdfScreen> createState() => _TextToPdfScreenState();
}

class _TextToPdfScreenState extends ConsumerState<TextToPdfScreen> {
  final _text = TextEditingController();
  final _name = TextEditingController(text: 'Document.pdf');
  double _size = 11;

  @override
  void initState() {
    super.initState();
    final txt = widget.initial.where((f) => f.kind == FileKind.text).firstOrNull;
    if (txt != null) _load(txt);
  }

  Future<void> _load(InputFile f) async {
    try {
      final content = await File(f.path).readAsString();
      setState(() {
        _text.text = content;
        _name.text = derivedName(f.name, '', extension: 'pdf');
      });
    } on FileSystemException catch (e) {
      if (mounted) showMessage(context, 'Could not read ${f.name}: ${e.message}');
    } on FormatException {
      if (mounted) showMessage(context, '${f.name} is not UTF-8 text.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(nativeApiProvider);
    return ToolScaffold(
      title: 'Text to PDF',
      about:
          'Turns plain text into a paginated, searchable PDF. Latin, Devanagari and Telugu characters '
          'are supported; complex Indic letter combinations may not be shaped perfectly.',
      actionLabel: 'Create PDF',
      actionIcon: Icons.picture_as_pdf_outlined,
      canRun: () => _text.text.trim().isEmpty ? 'Type or paste some text' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            onPressed: () async {
              final picked = await pickInputs(context, ref, accept: Accept.text);
              if (picked.isNotEmpty) await _load(picked.first);
            },
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Open a .txt file'),
          ),
          const SizedBox(height: Gaps.l),
          TextField(
            controller: _text,
            minLines: 8,
            maxLines: 16,
            decoration: const InputDecoration(labelText: 'Text', alignLabelWithHint: true),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Gaps.l),
          LabeledSlider(
            label: 'Font size',
            value: _size,
            min: 8,
            max: 20,
            divisions: 12,
            onChanged: (v) => setState(() => _size = v),
          ),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'File name'),
          ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        var name = sanitizeFileName(_name.text.trim().isEmpty ? 'Document' : _name.text.trim());
        if (!name.toLowerCase().endsWith('.pdf')) name = '$name.pdf';
        final out = await ws.newWorkFile(name);
        await api.textToPdf(_text.text, out, fontSize: _size, jobId: job.id);
        return ToolResult(headline: 'PDF created', outputs: [OutputFile(out, name)], checks: await verifyPdf(api, out));
      },
    );
  }
}

class PdfToTextScreen extends ConsumerStatefulWidget {
  const PdfToTextScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<PdfToTextScreen> createState() => _PdfToTextScreenState();
}

class _PdfToTextScreenState extends ConsumerState<PdfToTextScreen> with PdfInputs {
  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    final info = firstInfo;
    return ToolScaffold(
      title: 'PDF to text',
      about:
          'Extracts the selectable text of each page into a .txt file. Layout, images and tables are '
          'not preserved. Scanned PDFs have no text layer; use “Make PDF searchable (OCR)” for those.',
      actionLabel: 'Extract text',
      actionIcon: Icons.notes_rounded,
      canRun: () => first == null ? 'Choose a PDF' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(),
          if (info != null && !info.hasText) ...[
            const SizedBox(height: Gaps.l),
            const MessageBanner(
              kind: BannerKind.warning,
              message: 'This PDF looks scanned: it contains little or no selectable text. Run OCR first to recognise the text.',
            ),
          ],
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final f = first!;
        final texts = await withOwnerPassword(
          this,
          f,
          () => api.extractText(f.path, password: f.password, jobId: job.id),
        );
        final buffer = StringBuffer();
        for (var i = 0; i < texts.length; i++) {
          if (texts.length > 1) buffer.writeln('--- Page ${i + 1} ---');
          buffer.writeln(texts[i].trimRight());
          buffer.writeln();
        }
        final text = buffer.toString().trim();
        final name = derivedName(f.name, '', extension: 'txt');
        final out = await ws.newWorkFile(name);
        await File(out).writeAsString(text);
        final chars = texts.fold<int>(0, (a, t) => a + t.trim().length);
        return ToolResult(
          headline: chars == 0 ? 'No text found' : 'Extracted text from ${pages(texts.length)}',
          outputs: chars == 0 ? const [] : [OutputFile(out, name)],
          checks: [Check('${pages(texts.length)} processed', texts.length == info?.pageCount)],
          notes: chars == 0
              ? ['This PDF has no selectable text. Use OCR to recognise text in scanned pages.']
              : const [],
          copyText: text,
        );
      },
    );
  }
}

const ocrScripts = {
  'latin': 'English and other Latin-script languages',
  'devanagari': 'Hindi (Devanagari) and English',
};

/// OCR language picker with an explicit note about unsupported scripts.
class OcrScriptPicker extends StatelessWidget {
  const OcrScriptPicker({super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => OptionGroup(
    title: 'Language',
    children: [
      RadioGroup<String>(
        groupValue: value,
        onChanged: (v) => onChanged(v!),
        child: Column(
          children: [
            for (final e in ocrScripts.entries)
              RadioListTile<String>(contentPadding: EdgeInsets.zero, value: e.key, title: Text(e.value)),
          ],
        ),
      ),
      const MessageBanner(
        message:
            'Telugu text recognition is not available yet: the on-device recognition engine '
            'used by SnapPDF does not support Telugu script.',
      ),
    ],
  );
}

class OcrPdfScreen extends ConsumerStatefulWidget {
  const OcrPdfScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<OcrPdfScreen> createState() => _OcrPdfScreenState();
}

class _OcrPdfScreenState extends ConsumerState<OcrPdfScreen> with PdfInputs {
  late String _script = ref.read(settingsProvider).ocrScript;
  late List<InputFile> _images = widget.initial.where((f) => f.kind == FileKind.image).toList();
  bool _force = false;

  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  bool get _fromImages => _images.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      title: 'Make PDF searchable',
      about:
          'Recognises text on scanned pages or photos (on your device, nothing is uploaded) and adds an '
          'invisible text layer, so you can search, select and copy text. The visible page is not changed. '
          'Accuracy depends on image quality; handwriting is usually not recognised.',
      actionLabel: 'Recognise text',
      actionIcon: Icons.document_scanner_outlined,
      canRun: () => first == null && !_fromImages ? 'Choose a scanned PDF or images' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_fromImages) pdfInputsCard(emptyLabel: 'Choose a scanned PDF'),
          if (first == null) ...[
            if (!_fromImages) ...[
              const SizedBox(height: Gaps.m),
              Center(child: Text('or', style: Theme.of(context).textTheme.bodySmall)),
              const SizedBox(height: Gaps.m),
            ],
            InputsCard(
              inputs: _images,
              accept: Accept.image,
              multiple: true,
              reorderable: true,
              emptyLabel: 'Add photos of pages',
              onChanged: (l) => setState(() => _images = l),
            ),
          ],
          const SizedBox(height: Gaps.xl),
          OcrScriptPicker(value: _script, onChanged: (v) => setState(() => _script = v)),
          if (first != null && (firstInfo?.hasText ?? false))
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _force,
              onChanged: (v) => setState(() => _force = v),
              title: const Text('Also process pages that already have text'),
            ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final ({int pages, int lines, String text}) r;
        final String name;
        final String out;
        if (_fromImages) {
          name = 'Scanned text.pdf';
          out = await ws.newWorkFile(name);
          r = await api.imagesToSearchablePdf([for (final i in _images) i.path], out, script: _script, jobId: job.id);
        } else {
          final f = first!;
          name = derivedName(f.name, 'searchable', extension: 'pdf');
          out = await ws.newWorkFile(name);
          r = await withOwnerPassword(
            this,
            f,
            () => api.ocrPdf(f.path, f.password, out, script: _script, force: _force, jobId: job.id),
          );
        }
        final textCheck = (await api.extractText(out)).join(' ').trim();
        return ToolResult(
          headline: r.lines == 0 ? 'No text was recognised' : 'Recognised ${r.lines} lines on ${pages(r.pages)}',
          outputs: [OutputFile(out, name)],
          checks: [
            ...await verifyPdf(api, out, expectedPages: _fromImages ? _images.length : firstInfo?.pageCount),
            Check('Text can be searched and copied', textCheck.isNotEmpty),
          ],
          notes: [if (r.lines == 0) 'No readable text was found. Try a sharper, well-lit scan.', ...securityNotes()],
          copyText: r.text,
        );
      },
    );
  }
}

class ImageToTextScreen extends ConsumerStatefulWidget {
  const ImageToTextScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<ImageToTextScreen> createState() => _ImageToTextScreenState();
}

class _ImageToTextScreenState extends ConsumerState<ImageToTextScreen> {
  late List<InputFile> _images = widget.initial.where((f) => f.kind == FileKind.image).toList();
  late String _script = ref.read(settingsProvider).ocrScript;

  @override
  Widget build(BuildContext context) {
    final api = ref.read(nativeApiProvider);
    return ToolScaffold(
      title: 'Image to text',
      about: 'Recognises printed text in photos and screenshots on your device. Nothing is uploaded.',
      actionLabel: 'Recognise text',
      actionIcon: Icons.text_snippet_outlined,
      canRun: () => _images.isEmpty ? 'Add an image' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InputsCard(
            inputs: _images,
            accept: Accept.image,
            multiple: true,
            emptyLabel: 'Add images with text',
            onChanged: (l) => setState(() => _images = l),
          ),
          const SizedBox(height: Gaps.xl),
          OcrScriptPicker(value: _script, onChanged: (v) => setState(() => _script = v)),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final buffer = StringBuffer();
        var lines = 0;
        for (var i = 0; i < _images.length; i++) {
          job.throwIfCancelled();
          job.report(i, _images.length, 'Reading ${_images[i].name}');
          final r = await api.recognizeText(_images[i].path, script: _script);
          lines += r.lines.length;
          if (_images.length > 1) buffer.writeln('--- ${_images[i].name} ---');
          buffer.writeln(r.text);
          buffer.writeln();
        }
        final text = buffer.toString().trim();
        final outputs = <OutputFile>[];
        if (text.isNotEmpty) {
          final name = _images.length == 1
              ? derivedName(_images.first.name, 'text', extension: 'txt')
              : 'Recognised text.txt';
          final out = await ws.newWorkFile(name);
          await File(out).writeAsString(text);
          outputs.add(OutputFile(out, name));
        }
        return ToolResult(
          headline: lines == 0 ? 'No text was recognised' : 'Recognised $lines lines',
          outputs: outputs,
          copyText: text,
          notes: lines == 0 ? const ['Try a sharper photo with good lighting, taken straight on.'] : const [],
        );
      },
    );
  }
}

class ScanDocumentScreen extends ConsumerStatefulWidget {
  const ScanDocumentScreen({super.key});

  @override
  ConsumerState<ScanDocumentScreen> createState() => _ScanDocumentScreenState();
}

class _ScanDocumentScreenState extends ConsumerState<ScanDocumentScreen> {
  List<InputFile> _pages = [];
  bool _searchable = true;
  late String _script = ref.read(settingsProvider).ocrScript;
  final _name = TextEditingController(text: 'Scan.pdf');
  bool? _scannerAvailable;
  String? _scanError;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final ok = await ref.read(nativeApiProvider).scannerAvailable().catchError((_) => false);
    if (mounted) setState(() => _scannerAvailable = ok);
    if (ok && _pages.isEmpty) unawaited(_scan());
  }

  Future<void> _scan() async {
    final api = ref.read(nativeApiProvider);
    try {
      final paths = await api.scanDocument();
      if (!mounted || paths.isEmpty) return;
      final added = [
        for (final (i, path) in paths.indexed)
          InputFile(path: path, name: 'Page ${_pages.length + i + 1}.jpg', size: await File(path).length()),
      ];
      setState(() {
        _pages = [..._pages, ...added];
        _scanError = null;
      });
    } on NativeError catch (e) {
      if (mounted) setState(() => _scanError = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(nativeApiProvider);
    return ToolScaffold(
      title: 'Scan document',
      about:
          'Uses the Google document scanner on your device: automatic edge detection, perspective '
          'correction, cropping and colour, grayscale or black-and-white cleanup. Pages are saved as a PDF, '
          'optionally made searchable with on-device OCR. If the scanner is not available on this device, '
          'you can take photos instead and crop them in Photo editor.',
      actionLabel: _pages.isEmpty ? 'Save PDF' : 'Save PDF (${pages(_pages.length)})',
      actionIcon: Icons.save_alt_rounded,
      canRun: () => _pages.isEmpty ? 'Scan at least one page' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_scannerAvailable == false)
            const MessageBanner(
              kind: BannerKind.warning,
              title: 'Scanner not available',
              message:
                  'The Google document scanner is not installed on this device (it needs Google Play services). '
                  'You can still add photos of your pages below.',
            ),
          if (_scanError != null) ...[
            MessageBanner(kind: BannerKind.error, message: _scanError!),
            const SizedBox(height: Gaps.m),
          ],
          if (_scannerAvailable ?? false) ...[
            FilledButton.tonalIcon(
              onPressed: _scan,
              icon: const Icon(Icons.document_scanner_outlined),
              label: Text(_pages.isEmpty ? 'Start scanning' : 'Scan more pages'),
            ),
            const SizedBox(height: Gaps.l),
          ],
          InputsCard(
            inputs: _pages,
            accept: Accept.image,
            multiple: true,
            reorderable: true,
            emptyLabel: _scannerAvailable == false ? 'Add photos of pages' : 'Scanned pages appear here',
            onChanged: (l) => setState(() => _pages = l),
          ),
          const SizedBox(height: Gaps.xl),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _searchable,
            onChanged: (v) => setState(() => _searchable = v),
            title: const Text('Make text searchable (OCR)'),
            subtitle: const Text('Recognised on your device'),
          ),
          if (_searchable) OcrScriptPicker(value: _script, onChanged: (v) => setState(() => _script = v)),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'File name'),
          ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        var name = sanitizeFileName(_name.text.trim().isEmpty ? 'Scan' : _name.text.trim());
        if (!name.toLowerCase().endsWith('.pdf')) name = '$name.pdf';
        final out = await ws.newWorkFile(name);
        final images = [for (final pg in _pages) pg.path];
        String? text;
        if (_searchable) {
          final r = await api.imagesToSearchablePdf(images, out, script: _script, jobId: job.id);
          text = r.text;
        } else {
          await api.imagesToPdf(images, out, quality: 'original', jobId: job.id);
        }
        return ToolResult(
          headline: 'Saved ${pages(_pages.length)} as PDF',
          outputs: [OutputFile(out, name)],
          checks: [
            ...await verifyPdf(api, out, expectedPages: _pages.length),
            if (_searchable) Check('Text layer added', (text ?? '').trim().isNotEmpty),
          ],
          copyText: text,
          notes: _searchable && (text ?? '').trim().isEmpty
              ? const ['No text was recognised on these pages.']
              : const [],
        );
      },
    );
  }
}
