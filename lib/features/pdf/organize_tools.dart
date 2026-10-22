import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import '../../core/util/page_ranges.dart';
import 'pdf_common.dart';

class MergePdfScreen extends ConsumerStatefulWidget {
  const MergePdfScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<MergePdfScreen> createState() => _MergePdfScreenState();
}

class _MergePdfScreenState extends ConsumerState<MergePdfScreen> with PdfInputs {
  final _name = TextEditingController(text: 'Merged.pdf');

  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  int get _totalPages => inputs.fold(0, (a, f) => a + (infoOf(f)?.pageCount ?? 0));

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      title: 'Merge PDFs',
      about:
          'Combines PDFs into one document in the order shown. Drag the handles to reorder. '
          'Form fields and bookmarks are kept where possible. Password-protected files are '
          'unlocked with the password you enter; the merged file is not password protected.',
      actionLabel: inputs.length < 2 ? 'Merge' : 'Merge ${inputs.length} files',
      actionIcon: Icons.call_merge_rounded,
      canRun: () => inputs.length < 2 ? 'Add at least two PDFs' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(multiple: true, reorderable: true, emptyLabel: 'Add PDFs to merge'),
          if (inputs.length >= 2) ...[
            const SizedBox(height: Gaps.s),
            Text('${pages(_totalPages)} in total', style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: Gaps.xl),
          OptionGroup(
            title: 'File name',
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
            ],
          ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final name = sanitizeFileName(_name.text.trim().isEmpty ? 'Merged' : _name.text.trim());
        final out = await ws.newWorkFile(name.toLowerCase().endsWith('.pdf') ? name : '$name.pdf');
        await api.merge([for (final f in inputs) (path: f.path, password: f.password)], out, jobId: job.id);
        final checks = await verifyPdf(api, out, expectedPages: _totalPages);
        return ToolResult(
          headline: 'Merged ${inputs.length} PDFs',
          outputs: [OutputFile(out, name.toLowerCase().endsWith('.pdf') ? name : '$name.pdf')],
          checks: checks,
          notes: securityNotes(),
        );
      },
    );
  }
}

enum SplitMode { extract, ranges, everyN, single }

class SplitPdfScreen extends ConsumerStatefulWidget {
  const SplitPdfScreen({super.key, this.initial = const [], this.extractOnly = false});
  final List<InputFile> initial;
  final bool extractOnly;

  @override
  ConsumerState<SplitPdfScreen> createState() => _SplitPdfScreenState();
}

class _SplitPdfScreenState extends ConsumerState<SplitPdfScreen> with PdfInputs {
  late SplitMode _mode = widget.extractOnly ? SplitMode.extract : SplitMode.ranges;
  final _ranges = TextEditingController();
  final _everyN = TextEditingController(text: '1');
  String? _rangeError;

  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  int get _count => firstInfo?.pageCount ?? 0;

  /// Output groups of 0-based page indices, or null if invalid.
  List<List<int>>? _groups() {
    if (_count == 0) return null;
    try {
      return switch (_mode) {
        SplitMode.extract => [parsePageSelection(_ranges.text, _count)],
        SplitMode.ranges => parsePageRanges(_ranges.text, _count),
        SplitMode.everyN => chunkPages(_count, int.tryParse(_everyN.text) ?? 0),
        SplitMode.single => chunkPages(_count, 1),
      };
    } on FormatException {
      return null;
    }
  }

  void _validate() {
    String? err;
    if (_mode == SplitMode.extract || _mode == SplitMode.ranges) {
      if (_ranges.text.trim().isNotEmpty && _count > 0) {
        try {
          parsePageRanges(_ranges.text, _count);
        } on FormatException catch (e) {
          err = e.message;
        }
      }
    }
    setState(() => _rangeError = err);
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups();
    final t = Theme.of(context).textTheme;
    return ToolScaffold(
      title: widget.extractOnly ? 'Extract pages' : 'Split PDF',
      about:
          'Creates new PDFs from selected pages. Pages that are not included are removed from the '
          'output file entirely, including links and bookmarks that point to them.',
      actionLabel: groups == null || groups.length <= 1 ? 'Create PDF' : 'Create ${groups.length} PDFs',
      actionIcon: Icons.call_split_rounded,
      canRun: () {
        if (first == null) return 'Choose a PDF';
        if (groups == null || groups.isEmpty) return 'Enter valid pages';
        if (groups.length > 200) return 'That would create more than 200 files';
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(onChange: _validate),
          const SizedBox(height: Gaps.xl),
          if (!widget.extractOnly)
            OptionGroup(
              title: 'How to split',
              children: [
                Wrap(
                  spacing: Gaps.s,
                  runSpacing: Gaps.s,
                  children: [
                    for (final m in SplitMode.values)
                      ChoiceChip(
                        label: Text(switch (m) {
                          SplitMode.extract => 'Extract into one file',
                          SplitMode.ranges => 'By ranges',
                          SplitMode.everyN => 'Every N pages',
                          SplitMode.single => 'Every page',
                        }),
                        selected: _mode == m,
                        onSelected: (_) {
                          setState(() => _mode = m);
                          _validate();
                        },
                      ),
                  ],
                ),
              ],
            ),
          if (_mode == SplitMode.extract || _mode == SplitMode.ranges)
            OptionGroup(
              title: _mode == SplitMode.extract ? 'Pages to keep' : 'Ranges (one file per range)',
              subtitle: _count > 0 ? 'This PDF has ${pages(_count)}.' : null,
              children: [PageRangeField(controller: _ranges, error: _rangeError, onChanged: (_) => _validate())],
            ),
          if (_mode == SplitMode.everyN)
            OptionGroup(
              title: 'Pages per file',
              children: [
                TextField(
                  controller: _everyN,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Pages per file'),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          if (groups != null && groups.isNotEmpty)
            Text(
              groups.length == 1 ? 'Result: 1 PDF with ${pages(groups.first.length)}' : 'Result: ${groups.length} PDFs',
              style: t.bodyMedium,
            ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final input = first!;
        final outputs = <OutputFile>[];
        final checks = <Check>[];
        final gs = groups!;
        for (var i = 0; i < gs.length; i++) {
          job.throwIfCancelled();
          job.report(i, gs.length, 'Creating file ${i + 1} of ${gs.length}');
          final g = gs[i];
          final label = g.length == 1
              ? 'page_${g.first + 1}'
              : 'pages_${formatPageSelection(g).replaceAll(', ', '_').replaceAll(' ', '')}';
          final name = derivedName(
            input.name,
            gs.length == 1 && _mode == SplitMode.extract ? 'extract' : label,
            extension: 'pdf',
          );
          final out = await ws.newWorkFile(name);
          await withOwnerPassword(
            this,
            input,
            () => api.assemble(
              [(path: input.path, password: input.password)],
              [
                for (final p in g) {'source': 0, 'page': p},
              ],
              out,
              jobId: job.id,
            ),
          );
          outputs.add(OutputFile(out, name));
          final c = await verifyPdf(api, out, expectedPages: g.length);
          if (c.any((x) => !x.passed) || i == 0) checks.addAll(c);
        }
        return ToolResult(
          headline: outputs.length == 1
              ? 'Created a PDF with ${pages(gs.first.length)}'
              : 'Created ${outputs.length} PDFs',
          outputs: outputs,
          checks: checks,
          notes: securityNotes(),
        );
      },
    );
  }
}

enum CompressPreset { quality, balanced, smallest, target }

class CompressPdfScreen extends ConsumerStatefulWidget {
  const CompressPdfScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<CompressPdfScreen> createState() => _CompressPdfScreenState();
}

class _CompressPdfScreenState extends ConsumerState<CompressPdfScreen> with PdfInputs {
  CompressPreset _preset = CompressPreset.balanced;
  final _target = TextEditingController();
  bool _targetInMb = false;
  bool _grayscale = false;

  static const _ladder = <(int, double)>[(220, 0.85), (150, 0.72), (120, 0.6), (96, 0.5), (72, 0.4), (60, 0.3)];

  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  int? get _targetBytes {
    final v = double.tryParse(_target.text.replaceAll(',', '.'));
    if (v == null || v <= 0) return null;
    return (v * (_targetInMb ? 1024 * 1024 : 1024)).round();
  }

  (int, double) _settings(CompressPreset p) => switch (p) {
    CompressPreset.quality => (200, 0.85),
    CompressPreset.balanced => (150, 0.72),
    CompressPreset.smallest => (96, 0.5),
    CompressPreset.target => (150, 0.72),
  };

  @override
  Widget build(BuildContext context) {
    final strip = ref.watch(settingsProvider).stripPdfMetadata;
    return ToolScaffold(
      title: 'Compress PDF',
      about:
          'Reduces size by downsampling and recompressing embedded images, compressing page '
          'content and removing unneeded metadata. Text and vector graphics stay sharp. PDFs that '
          'contain mostly text or already-optimised images may shrink very little. A target size '
          'is a goal, not a guarantee: if it cannot be reached you get the smallest result and an explanation.',
      actionLabel: inputs.length > 1 ? 'Compress ${inputs.length} PDFs' : 'Compress',
      actionIcon: Icons.compress_rounded,
      canRun: () {
        if (inputs.isEmpty) return 'Choose a PDF';
        if (_preset == CompressPreset.target && _targetBytes == null) return 'Enter a target size';
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(multiple: true),
          const SizedBox(height: Gaps.xl),
          OptionGroup(
            title: 'Compression level',
            children: [
              RadioGroup<CompressPreset>(
                groupValue: _preset,
                onChanged: (v) => setState(() => _preset = v!),
                child: Column(
                  children: [
                    for (final p in CompressPreset.values)
                      RadioListTile<CompressPreset>(
                        contentPadding: EdgeInsets.zero,
                        value: p,
                        title: Text(switch (p) {
                          CompressPreset.quality => 'High quality',
                          CompressPreset.balanced => 'Balanced (recommended)',
                          CompressPreset.smallest => 'Smallest size',
                          CompressPreset.target => 'Custom maximum size',
                        }),
                        subtitle: Text(switch (p) {
                          CompressPreset.quality => 'Images at 200 dpi; minimal visible change',
                          CompressPreset.balanced => 'Images at 150 dpi; good for sharing and email',
                          CompressPreset.smallest => 'Images at 96 dpi; fine for screens, softer when printed',
                          CompressPreset.target => 'Tries stronger settings until the file fits',
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (_preset == CompressPreset.target)
            OptionGroup(
              title: 'Maximum size',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _target,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Size'),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: Gaps.m),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('KB')),
                        ButtonSegment(value: true, label: Text('MB')),
                      ],
                      selected: {_targetInMb},
                      onSelectionChanged: (v) => setState(() => _targetInMb = v.first),
                    ),
                  ],
                ),
              ],
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _grayscale,
            onChanged: (v) => setState(() => _grayscale = v),
            title: const Text('Convert images to grayscale'),
            subtitle: const Text('Smaller files for scanned documents'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: strip,
            onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(stripPdfMetadata: v)),
            title: const Text('Remove metadata'),
            subtitle: const Text('Author, software and other hidden document information'),
          ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final outputs = <OutputFile>[];
        final checks = <Check>[];
        final notes = <String>[...securityNotes()];
        var before = 0;
        var after = 0;
        String? previewIn;
        String? previewInPw;
        for (var i = 0; i < inputs.length; i++) {
          job.throwIfCancelled();
          final f = inputs[i];
          job.report(i, inputs.length, 'Compressing ${f.name}');
          final name = derivedName(f.name, 'compressed', extension: 'pdf');
          String best;
          int bestSize;
          if (_preset != CompressPreset.target) {
            final (dpi, q) = _settings(_preset);
            best = await ws.newWorkFile(name);
            final r = await withOwnerPassword(
              this,
              f,
              () => api.compress(
                f.path,
                f.password,
                best,
                maxDpi: dpi,
                jpegQuality: q,
                stripMetadata: strip,
                grayscale: _grayscale,
                jobId: job.id,
              ),
            );
            bestSize = r.outputBytes;
            if (r.outputBytes >= r.inputBytes && f.password == null) {
              // Never hand back a bigger file: keep an exact copy of the original.
              await File(f.path).copy(best);
              bestSize = r.inputBytes;
              notes.add(
                '${f.name} could not be made smaller, so the original was kept unchanged.'
                '${r.imagesRecompressed == 0 ? ' It contains no images that can be reduced.' : ''}',
              );
            } else if (r.outputBytes >= r.inputBytes * 0.98) {
              notes.add('${f.name} is already well optimised; compression saved little.');
            }
          } else {
            final target = _targetBytes!;
            best = '';
            bestSize = 1 << 62;
            var met = false;
            for (final (dpi, q) in _ladder) {
              job.throwIfCancelled();
              final out = await ws.newWorkFile(name);
              job.message.value = 'Trying $dpi dpi…';
              final r = await withOwnerPassword(
                this,
                f,
                () => api.compress(
                  f.path,
                  f.password,
                  out,
                  maxDpi: dpi,
                  jpegQuality: q,
                  stripMetadata: strip,
                  grayscale: _grayscale,
                  jobId: job.id,
                ),
              );
              if (r.outputBytes < bestSize) {
                best = out;
                bestSize = r.outputBytes;
              }
              if (r.outputBytes <= target) {
                met = true;
                best = out;
                bestSize = r.outputBytes;
                if (dpi < 120) {
                  notes.add('${f.name}: images were reduced to $dpi dpi to fit; they may look soft when printed.');
                }
                break;
              }
              if (r.imagesRecompressed == 0) break; // nothing left to shrink
            }
            checks.add(
              Check(
                '${f.name}: ${met ? 'fits' : 'does not fit'} ${formatBytes(target)} (${formatBytes(bestSize)})',
                met,
              ),
            );
            if (!met) {
              notes.add(
                '${f.name}: the smallest achievable size is ${formatBytes(bestSize)}. Most of this file '
                'is text, fonts or vector graphics, which cannot be reduced without losing quality. '
                'Splitting the document or removing pages would reduce it further.',
              );
            }
          }
          before += f.size;
          after += bestSize;
          outputs.add(OutputFile(best, name));
          final c = await verifyPdf(api, best, expectedPages: infoOf(f)?.pageCount);
          checks.addAll(c.map((x) => Check(inputs.length > 1 ? '${f.name}: ${x.label}' : x.label, x.passed)));
          if (i == 0) {
            previewIn = f.path;
            previewInPw = f.password;
          }
        }
        return ToolResult(
          headline: after < before ? 'Reduced by ${formatBytes(before - after)}' : 'Compression finished',
          outputs: outputs,
          checks: checks,
          notes: notes,
          detail: (saved) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizeComparison(
                before: before,
                after: after,
                target: _preset == CompressPreset.target ? _targetBytes : null,
              ),
              if (previewIn != null) ...[
                const SizedBox(height: Gaps.xl),
                PdfBeforeAfter(before: previewIn, beforePassword: previewInPw, after: saved.first),
              ],
            ],
          ),
        );
      },
    );
  }
}
