import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/jobs/job.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import '../../core/util/page_ranges.dart';
import '../image/engine/image_engine.dart';
import '../image/engine/image_format.dart';
import '../image/image_tools.dart';
import 'smart_fix_plan.dart';

/// Task-oriented flow: describe the file you need, SnapPDF works out the steps,
/// runs them and checks the result against every requirement.
class SmartFixScreen extends ConsumerStatefulWidget {
  const SmartFixScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<SmartFixScreen> createState() => _SmartFixScreenState();
}

class _SmartFixScreenState extends ConsumerState<SmartFixScreen> {
  InputFile? _input;
  PdfInfo? _info;
  FixTarget _target = FixTarget.same;
  bool _useSize = false;
  final _size = TextEditingController(text: '200');
  bool _sizeMb = false;
  bool _useDims = false;
  final _w = TextEditingController();
  final _h = TextEditingController();
  bool _exact = false;
  final _pages = TextEditingController();

  @override
  void initState() {
    super.initState();
    final f = widget.initial.where((f) => f.kind == FileKind.pdf || f.kind == FileKind.image).firstOrNull;
    if (f != null) WidgetsBinding.instance.addPostFrameCallback((_) => _setInput(f));
  }

  Future<void> _setInput(InputFile? f) async {
    PdfInfo? info;
    if (f != null && f.kind == FileKind.pdf) {
      info = await probePdf(context, ref.read(nativeApiProvider), f);
      if (info == null) return;
    }
    setState(() {
      _input = f;
      _info = info;
    });
  }

  FixRequest get _request => FixRequest(
    inputKind: _input?.kind ?? FileKind.other,
    target: _target,
    maxBytes: _useSize ? SizeLimitField.bytes(_size.text, _sizeMb) : null,
    width: _useDims ? int.tryParse(_w.text) : null,
    height: _useDims ? int.tryParse(_h.text) : null,
    exactSize: _useDims && _exact,
    pages: _input?.kind == FileKind.pdf ? _pages.text : '',
    pageCount: _info?.pageCount,
  );

  @override
  Widget build(BuildContext context) {
    final req = _request;
    final errors = _input == null ? const <String>[] : validateFixRequest(req);
    final t = Theme.of(context).textTheme;
    return ToolScaffold(
      title: 'Smart File Fix',
      about:
          'Tell SnapPDF what the file must look like (format, maximum size, dimensions, pages). It plans and runs the '
          'steps on your device, then checks the result against every requirement and explains anything that could not be met.',
      actionLabel: 'Fix my file',
      actionIcon: Icons.auto_awesome_rounded,
      canRun: () {
        if (_input == null) return 'Choose a file';
        if (_useSize && req.maxBytes == null) return 'Enter the maximum size';
        if (_useDims && req.width == null && req.height == null) return 'Enter a width or height';
        return errors.isEmpty ? null : errors.first;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InputsCard(
            inputs: [?_input],
            accept: Accept.pdfOrImage,
            emptyLabel: 'Choose the file to fix',
            subtitleFor: (f) =>
                _info != null ? '${_info!.pageCount} pages · ${formatBytes(f.size)}' : formatBytes(f.size),
            onChanged: (l) => _setInput(l.isEmpty ? null : l.first),
          ),
          const SizedBox(height: Gaps.xl),
          OptionGroup(
            title: 'I need a…',
            children: [
              Wrap(
                spacing: Gaps.s,
                runSpacing: Gaps.s,
                children: [
                  for (final f in FixTarget.values)
                    ChoiceChip(
                      label: Text(f.label),
                      selected: _target == f,
                      onSelected: (_) => setState(() => _target = f),
                    ),
                ],
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _useSize,
            onChanged: (v) => setState(() => _useSize = v),
            title: const Text('Maximum file size'),
          ),
          if (_useSize) ...[
            SizeLimitField(
              controller: _size,
              inMb: _sizeMb,
              onUnit: (v) => setState(() => _sizeMb = v),
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: Gaps.m),
          ],
          if (req.outputIsImage) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _useDims,
              onChanged: (v) => setState(() => _useDims = v),
              title: const Text('Pixel dimensions'),
            ),
            if (_useDims) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _w,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Width (px)'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: Gaps.m),
                  Expanded(
                    child: TextField(
                      controller: _h,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Height (px)'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _exact,
                onChanged: (v) => setState(() => _exact = v ?? false),
                title: const Text('Exactly this size'),
                subtitle: const Text('Crops edges if needed; otherwise the image fits inside'),
              ),
            ],
          ],
          if (_input?.kind == FileKind.pdf) ...[
            const SizedBox(height: Gaps.m),
            TextField(
              controller: _pages,
              decoration: InputDecoration(
                labelText: 'Pages to keep (optional)',
                hintText: 'e.g. 1-2',
                helperText: _info != null ? 'This PDF has ${_info!.pageCount} pages' : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
          if (_input != null) ...[
            const SizedBox(height: Gaps.xl),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Gaps.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Plan', style: t.titleSmall),
                    const SizedBox(height: Gaps.s),
                    for (final (i, s) in describePlan(req).indexed)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 24, child: Text('${i + 1}.', style: t.bodyMedium)),
                            Expanded(child: Text(s, style: t.bodyMedium)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            for (final e in errors) ...[
              const SizedBox(height: Gaps.m),
              MessageBanner(kind: BannerKind.warning, message: e),
            ],
          ],
        ],
      ),
      run: (context, job) => _execute(context, job, req),
    );
  }

  Future<ToolResult> _execute(BuildContext context, JobHandle job, FixRequest req) async {
    final api = ref.read(nativeApiProvider);
    final ws = ref.read(workspaceProvider);
    final f = _input!;
    final checks = <Check>[];
    final notes = <String>[];
    final outputs = <OutputFile>[];
    final base = p.basenameWithoutExtension(f.name);

    ImgFormat? imageFormat() => switch (req.target) {
      FixTarget.jpg => ImgFormat.jpeg,
      FixTarget.png => ImgFormat.png,
      FixTarget.webp => ImgFormat.webp,
      _ => null,
    };
    ResizeSpec? resize() => req.width == null && req.height == null
        ? null
        : ResizeSpec(
            width: req.width,
            height: req.height,
            mode: req.exactSize ? ResizeMode.fill : ResizeMode.fit,
            allowUpscale: req.exactSize,
          );

    Future<void> imageStep(String path, String name, {bool fromPdf = false}) async {
      final bytes = await File(path).readAsBytes();
      final fmt = imageFormat() ?? (fromPdf ? ImgFormat.jpeg : null);
      final r = await processImage(
        bytes,
        ImageSpec(format: fmt, quality: 92, resize: resize(), targetBytes: req.maxBytes),
      );
      final outName = '$name.${r.format.extension}';
      final out = await ws.newWorkFile(outName);
      await File(out).writeAsBytes(r.bytes, flush: true);
      outputs.add(OutputFile(out, outName));
      final label = outputs.length > 1 || fromPdf ? '$outName: ' : '';
      final probe = probeImage(r.bytes);
      checks.add(Check('${label}valid ${r.format.label} image', probe.width > 0));
      if (req.exactSize) {
        checks.add(
          Check(
            '$label${req.width} × ${req.height} px (got ${probe.width} × ${probe.height})',
            probe.width == req.width && probe.height == req.height,
          ),
        );
      } else if (req.width != null || req.height != null) {
        final ok =
            (req.width == null || probe.width <= req.width!) && (req.height == null || probe.height <= req.height!);
        checks.add(
          Check(
            '${label}fits ${req.width ?? '∞'} × ${req.height ?? '∞'} px (got ${probe.width} × ${probe.height})',
            ok,
          ),
        );
      }
      if (req.maxBytes != null) {
        checks.add(
          Check(
            '${label}at most ${formatBytes(req.maxBytes!)} (got ${formatBytes(r.bytes.length)})',
            r.bytes.length <= req.maxBytes!,
          ),
        );
      }
      notes.addAll(r.notes.map((n) => '$label$n'));
    }

    Future<void> pdfSizeStep(String path, String name, String? password) async {
      var best = path;
      var bestSize = await File(path).length();
      if (req.maxBytes != null && bestSize > req.maxBytes!) {
        for (final (dpi, q) in const [(150, 0.72), (120, 0.6), (96, 0.5), (72, 0.4), (60, 0.3)]) {
          job.throwIfCancelled();
          job.message.value = 'Compressing ($dpi dpi)…';
          final out = await ws.newWorkFile('$name.pdf');
          final r = await withOwnerPassword(
            this,
            f,
            () => api.compress(path, password, out, maxDpi: dpi, jpegQuality: q, jobId: job.id),
          );
          if (r.outputBytes < bestSize) {
            best = out;
            bestSize = r.outputBytes;
          }
          if (r.outputBytes <= req.maxBytes! || r.imagesRecompressed == 0) break;
        }
      } else if (password != null) {
        // Produce an unprotected copy so the output is self-contained.
        final out = await ws.newWorkFile('$name.pdf');
        await api.unlock(path, password, out);
        best = out;
        bestSize = await File(out).length();
      }
      final outName = '$name.pdf';
      outputs.add(OutputFile(best, outName));
      checks.addAll(await verifyPdf(api, best));
      if (req.maxBytes != null) {
        final ok = bestSize <= req.maxBytes!;
        checks.add(Check('At most ${formatBytes(req.maxBytes!)} (got ${formatBytes(bestSize)})', ok));
        if (!ok) {
          notes.add(
            'The smallest achievable size is ${formatBytes(bestSize)}. Text, fonts and vector graphics cannot be '
            'compressed further without losing quality. Removing pages, or converting to images, would reduce it more.',
          );
        }
      }
    }

    if (req.pdfIn) {
      var src = f.path;
      String? password = f.password;
      final selected = req.pages.trim().isEmpty ? null : parsePageSelection(req.pages, _info!.pageCount);
      if (selected != null) {
        job.message.value = 'Selecting pages…';
        final out = await ws.newWorkFile('pages.pdf');
        await withOwnerPassword(
          this,
          f,
          () => api.assemble(
            [(path: f.path, password: f.password)],
            [
              for (final i in selected) {'source': 0, 'page': i},
            ],
            out,
            jobId: job.id,
          ),
        );
        src = out;
        password = null;
        checks.add(
          Check(
            '${selected.length} page${selected.length == 1 ? '' : 's'} kept',
            (await api.pdfInfo(out)).pageCount == selected.length,
          ),
        );
      }
      if (req.outputIsPdf) {
        await pdfSizeStep(src, '${base}_fixed', password);
      } else {
        // PDF -> image(s): render at a resolution suited to the requested size.
        final pageSize = (await api.pdfInfo(src, password: password)).pages.first;
        var dpi = 150.0;
        if (req.width != null) dpi = (req.width! / (pageSize.width / 72)).clamp(36, 600).toDouble();
        if (req.height != null && req.width == null) {
          dpi = (req.height! / (pageSize.height / 72)).clamp(36, 600).toDouble();
        }
        final dir = await ws.newWorkDir();
        job.message.value = 'Rendering pages…';
        final images = await withOwnerPassword(
          this,
          f,
          () => api.pdfToImages(
            src,
            password,
            dpi: dpi,
            format: 'png',
            outDir: dir.path,
            baseName: 'page',
            jobId: job.id,
          ),
        );
        for (final (i, img) in images.indexed) {
          job.throwIfCancelled();
          job.report(i, images.length, 'Optimising page ${i + 1}');
          await imageStep(img, images.length == 1 ? '${base}_fixed' : '${base}_page${i + 1}', fromPdf: true);
        }
      }
    } else {
      if (req.outputIsPdf) {
        // Optimise the image first so the PDF can meet a size limit.
        var imagePath = f.path;
        if (req.maxBytes != null) {
          final bytes = await File(f.path).readAsBytes();
          final r = await processImage(
            bytes,
            ImageSpec(format: ImgFormat.jpeg, quality: 90, targetBytes: (req.maxBytes! * 0.95).round() - 2048),
          );
          imagePath = await ws.newWorkFile('image.jpg');
          await File(imagePath).writeAsBytes(r.bytes, flush: true);
          notes.addAll(r.notes);
        }
        final out = await ws.newWorkFile('${base}_fixed.pdf');
        await api.imagesToPdf([imagePath], out, quality: 'original', jobId: job.id);
        await pdfSizeStep(out, '${base}_fixed', null);
      } else {
        await imageStep(f.path, '${base}_fixed');
      }
    }

    final allMet = checks.every((c) => c.passed);
    return ToolResult(
      headline: allMet ? 'Done — every requirement is met' : 'Done, but some requirements could not be met',
      outputs: outputs,
      checks: checks,
      notes: notes,
    );
  }
}
