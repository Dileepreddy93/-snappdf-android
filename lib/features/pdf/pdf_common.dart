import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';

/// Shared state for tools that operate on PDFs: probes added files (asking
/// for passwords) and keeps their [PdfInfo].
mixin PdfInputs<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  List<InputFile> inputs = [];
  final Map<String, PdfInfo> infos = {};

  NativeApi get api => ref.read(nativeApiProvider);

  PdfInfo? infoOf(InputFile f) => infos[f.path];
  InputFile? get first => inputs.isEmpty ? null : inputs.first;
  PdfInfo? get firstInfo => first == null ? null : infoOf(first!);

  /// Called once inputs passed to the tool (e.g. "Continue") are probed.
  void onInputsReady() {}

  void initInputs(List<InputFile> initial) {
    if (initial.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ok = await probeAdded(initial.where((f) => f.kind == FileKind.pdf).toList());
      if (!mounted) return;
      setState(() => inputs = ok);
      onInputsReady();
    });
  }

  Future<List<InputFile>> probeAdded(List<InputFile> added) async {
    final ok = <InputFile>[];
    for (final f in added) {
      try {
        final info = await probePdf(context, api, f);
        if (info != null) {
          infos[f.path] = info;
          ok.add(f);
        }
      } on NativeError catch (e) {
        if (mounted) showMessage(context, '${f.name}: ${e.message}');
      }
    }
    return ok;
  }

  String pdfSubtitle(InputFile f) {
    final info = infoOf(f);
    if (info == null) return formatBytes(f.size);
    final pages = '${info.pageCount} page${info.pageCount == 1 ? '' : 's'}';
    return '$pages · ${formatBytes(f.size)}${info.encrypted ? ' · protected' : ''}';
  }

  Widget pdfInputsCard({bool multiple = false, bool reorderable = false, String? emptyLabel, VoidCallback? onChange}) =>
      InputsCard(
        inputs: inputs,
        accept: Accept.pdf,
        multiple: multiple,
        reorderable: reorderable,
        emptyLabel: emptyLabel,
        onAdded: probeAdded,
        subtitleFor: pdfSubtitle,
        onChanged: (list) {
          setState(() => inputs = list);
          onChange?.call();
        },
      );

  /// Note for outputs of password-protected inputs.
  List<String> securityNotes() => [
    if (inputs.any((f) => infoOf(f)?.encrypted ?? false))
      'The result is not password protected. Use “Protect PDF” to add a password again.',
  ];
}

/// Before/after size bar.
class SizeComparison extends StatelessWidget {
  const SizeComparison({super.key, required this.before, required this.after, this.target});
  final int before;
  final int after;
  final int? target;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final saved = before > 0 ? (1 - after / before) * 100 : 0.0;
    final ratio = before > 0 ? (after / before).clamp(0.0, 1.0) : 1.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gaps.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: _stat(context, 'Before', formatBytes(before))),
                Expanded(child: _stat(context, 'After', formatBytes(after))),
                Expanded(
                  child: _stat(
                    context,
                    saved >= 0 ? 'Saved' : 'Larger',
                    '${saved.abs().toStringAsFixed(saved.abs() < 10 ? 1 : 0)}%',
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gaps.l),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  Container(height: 10, color: s.surfaceContainerHighest),
                  FractionallySizedBox(
                    widthFactor: ratio,
                    child: Container(height: 10, color: s.primary),
                  ),
                ],
              ),
            ),
            if (target != null) ...[
              const SizedBox(height: Gaps.s),
              Text('Target: ${formatBytes(target!)}', style: t.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: t.bodySmall),
        const SizedBox(height: 2),
        Text(value, style: t.titleMedium),
      ],
    );
  }
}

/// Side-by-side rendered previews of two PDFs' first page.
class PdfBeforeAfter extends ConsumerStatefulWidget {
  const PdfBeforeAfter({super.key, required this.before, this.beforePassword, required this.after, this.page = 0});
  final String before;
  final String? beforePassword;
  final String after;
  final int page;

  @override
  ConsumerState<PdfBeforeAfter> createState() => _PdfBeforeAfterState();
}

class _PdfBeforeAfterState extends ConsumerState<PdfBeforeAfter> {
  late final Future<List<String>> _renders = _render();

  Future<List<String>> _render() async {
    final api = ref.read(nativeApiProvider);
    final ws = ref.read(workspaceProvider);
    final dir = await ws.newWorkDir();
    final a = await api.renderPage(widget.before, widget.beforePassword, widget.page, 900, '${dir.path}/before.png');
    final b = await api.renderPage(widget.after, null, widget.page, 900, '${dir.path}/after.png');
    return [a, b];
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return FutureBuilder<List<String>>(
      future: _renders,
      builder: (context, snap) {
        if (snap.hasError) {
          debugPrint('Preview failed: ${snap.error}');
          return Text('Preview unavailable: ${snap.error}', style: t.bodySmall);
        }
        if (!snap.hasData) {
          return const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
        }
        Widget pane(String label, String path) => Expanded(
          child: Column(
            children: [
              Text(label, style: t.labelMedium),
              const SizedBox(height: Gaps.s),
              GestureDetector(
                onTap: () => _zoom(context, path),
                child: Card(child: Image.file(File(path), fit: BoxFit.contain)),
              ),
            ],
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Preview (page ${widget.page + 1}) · tap to zoom', style: t.titleSmall),
            const SizedBox(height: Gaps.s),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                pane('Before', snap.data![0]),
                const SizedBox(width: Gaps.m),
                pane('After', snap.data![1]),
              ],
            ),
          ],
        );
      },
    );
  }

  void _zoom(BuildContext context, String path) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(),
          body: InteractiveViewer(maxScale: 8, child: Center(child: Image.file(File(path)))),
        ),
      ),
    );
  }
}

String pages(int n) => '$n page${n == 1 ? '' : 's'}';

/// Text field for page ranges with live validation.
class PageRangeField extends StatelessWidget {
  const PageRangeField({
    super.key,
    required this.controller,
    required this.error,
    required this.onChanged,
    this.label = 'Pages',
    this.hint = 'e.g. 1-3, 5, 8-',
  });

  final TextEditingController controller;
  final String? error;
  final ValueChanged<String> onChanged;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: TextInputType.visiblePassword,
    autocorrect: false,
    decoration: InputDecoration(labelText: label, hintText: hint, errorText: error),
    onChanged: onChanged,
  );
}

/// Reports used across tools.
Future<List<Check>> outputChecks(NativeApi api, String path, int expectedPages) =>
    verifyPdf(api, path, expectedPages: expectedPages);
