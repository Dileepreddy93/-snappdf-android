import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../design/widgets.dart';
import '../files/file_kind.dart';
import '../files/library_store.dart';
import '../jobs/job.dart';
import '../platform/native_api.dart';
import '../providers.dart';
import 'inputs.dart';

/// A produced file waiting to be saved into the library.
class OutputFile {
  const OutputFile(this.path, this.name);
  final String path;
  final String name;
}

/// One verification performed on the output.
class Check {
  const Check(this.label, this.passed);
  final String label;
  final bool passed;
}

class ToolResult {
  const ToolResult({
    required this.headline,
    this.outputs = const [],
    this.checks = const [],
    this.notes = const [],
    this.copyText,
    this.detail,
  });

  final String headline;
  final List<OutputFile> outputs;
  final List<Check> checks;

  /// Explanations of trade-offs or unmet constraints.
  final List<String> notes;

  /// Text the user can copy (OCR, extracted text).
  final String? copyText;

  /// Optional extra widget shown above the outputs (e.g. size comparison).
  /// Extra content above the outputs (e.g. size comparison, preview). Built
  /// with the final saved paths of [outputs], because temporary output files
  /// are moved into the library before the result is shown.
  final Widget Function(List<String> savedPaths)? detail;
}

enum _Phase { idle, running, done, failed }

/// Standard tool page: inputs and options, a primary action, real progress
/// with cancellation, and a result view with save/share/continue actions.
class ToolScaffold extends ConsumerStatefulWidget {
  const ToolScaffold({
    super.key,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.run,
    this.canRun,
    this.about,
    this.onReset,
    this.actionIcon = Icons.play_arrow_rounded,
  });

  final String title;

  /// Inputs + options. Rebuilt by the owning state via setState.
  final Widget body;
  final String actionLabel;
  final IconData actionIcon;

  /// Returns null when ready, or a short reason why the action is disabled.
  final String? Function()? canRun;
  final Future<ToolResult> Function(BuildContext context, JobHandle job) run;

  /// What the tool does and its limitations (shown from the info button).
  final String? about;
  final VoidCallback? onReset;

  @override
  ConsumerState<ToolScaffold> createState() => _ToolScaffoldState();
}

class _ToolScaffoldState extends ConsumerState<ToolScaffold> {
  _Phase _phase = _Phase.idle;
  JobHandle? _job;
  String? _error;
  ToolResult? _result;
  List<LibraryEntry> _saved = const [];
  List<String> _duplicateNotes = const [];

  Future<void> _start() async {
    final api = ref.read(nativeApiProvider);
    setState(() {
      _phase = _Phase.running;
      _error = null;
    });
    try {
      final result = await JobHandle.run(api, (job) async {
        final r = await widget.run(context, job);
        job.throwIfCancelled();
        return r;
      }, onStart: (job) => setState(() => _job = job));
      // Persist outputs into the private library.
      final saved = <LibraryEntry>[];
      final dupNotes = <String>[];
      final library = ref.read(libraryProvider.notifier);
      for (final o in result.outputs) {
        final r = await library.addOutput(o.path, o.name, action: widget.title);
        saved.add(r.entry);
        if (r.duplicateOf != null) {
          dupNotes.add('“${r.entry.name}” is identical to “${r.duplicateOf!.name}” already in your files.');
        }
      }
      if (!mounted) return;
      setState(() {
        _result = result;
        _saved = saved;
        _duplicateNotes = dupNotes;
        _phase = _Phase.done;
        _job = null;
      });
      unawaited(SemanticsService.sendAnnouncement(View.of(context), result.headline, TextDirection.ltr));
    } on NativeError catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = e.isCancelled ? _Phase.idle : _Phase.failed;
        _error = e.isCancelled ? null : e.message;
        _job = null;
      });
      if (e.isCancelled) showMessage(context, 'Cancelled. Nothing was saved.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '$e';
        _job = null;
      });
    }
  }

  Future<bool> _confirmLeave() async {
    if (_phase != _Phase.running) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop processing?'),
        content: const Text('The current operation will be cancelled and nothing will be saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep going')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Stop')),
        ],
      ),
    );
    if (leave == true) await _job?.cancel();
    return leave == true;
  }

  void _reset() {
    setState(() {
      _phase = _Phase.idle;
      _result = null;
      _saved = const [];
      _error = null;
    });
    widget.onReset?.call();
  }

  @override
  Widget build(BuildContext context) {
    final reason = widget.canRun?.call();
    return PopScope(
      canPop: _phase != _Phase.running,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            if (widget.about != null)
              IconButton(
                tooltip: 'About this tool',
                icon: const Icon(Icons.info_outline_rounded),
                onPressed: () => showModalBottomSheet(
                  useRootNavigator: true,
                  context: context,
                  builder: (context) => SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(Gaps.page, 0, Gaps.page, Gaps.xl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: Gaps.m),
                          Text(widget.about!, style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: switch (_phase) {
            _Phase.done => ResultView(
              key: const ValueKey('result'),
              result: _result!,
              saved: _saved,
              extraNotes: _duplicateNotes,
              onAgain: _reset,
            ),
            _ => KeyedSubtree(
              key: const ValueKey('form'),
              child: Stack(
                children: [
                  AbsorbPointer(
                    absorbing: _phase == _Phase.running,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.s, Gaps.page, 140),
                      children: [
                        if (_error != null) ...[
                          MessageBanner(kind: BannerKind.error, title: 'That didn’t work', message: _error!),
                          const SizedBox(height: Gaps.l),
                        ],
                        widget.body,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          },
        ),
        bottomNavigationBar: _phase == _Phase.done
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.s, Gaps.page, Gaps.m),
                  child: _phase == _Phase.running && _job != null
                      ? _ProgressBar(job: _job!)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (reason != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: Gaps.s),
                                child: Text(
                                  reason,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            FilledButton.icon(
                              onPressed: reason == null && _phase != _Phase.running ? _start : null,
                              icon: Icon(widget.actionIcon),
                              label: Text(widget.actionLabel),
                            ),
                          ],
                        ),
                ),
              ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.job});
  final JobHandle job;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ValueListenableBuilder<String?>(
                valueListenable: job.message,
                builder: (_, m, _) =>
                    Text(m ?? 'Processing…', style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: Gaps.s),
              ValueListenableBuilder<double?>(
                valueListenable: job.progress,
                builder: (_, v, _) => Semantics(
                  label: 'Progress',
                  value: v == null ? 'in progress' : '${(v * 100).round()} percent',
                  child: LinearProgressIndicator(value: v, minHeight: 6),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: Gaps.l),
        OutlinedButton(onPressed: job.cancel, child: const Text('Cancel')),
      ],
    );
  }
}

/// Shows verified outputs and what to do next.
class ResultView extends ConsumerWidget {
  const ResultView({
    super.key,
    required this.result,
    required this.saved,
    required this.onAgain,
    this.extraNotes = const [],
  });

  final ToolResult result;
  final List<LibraryEntry> saved;
  final List<String> extraNotes;
  final VoidCallback onAgain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final store = ref.read(libraryStoreProvider);
    final allPassed = result.checks.every((c) => c.passed);
    final notes = [...result.notes, ...extraNotes];
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.s, Gaps.page, Gaps.xxl),
      children: [
        Row(
          children: [
            ToneIcon(
              allPassed ? Icons.check_rounded : Icons.priority_high_rounded,
              tone: allPassed ? Tone.primary : Tone.danger,
              size: 48,
            ),
            const SizedBox(width: Gaps.l),
            Expanded(child: Text(result.headline, style: t.titleLarge)),
          ],
        ),
        if (result.detail != null) ...[
          const SizedBox(height: Gaps.xl),
          result.detail!([for (final e in saved) store.fileOf(e).path]),
        ],
        if (result.checks.isNotEmpty) ...[
          const SizedBox(height: Gaps.xl),
          Text('Verified', style: t.titleSmall),
          const SizedBox(height: Gaps.s),
          for (final c in result.checks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    c.passed ? Icons.check_circle_rounded : Icons.cancel_rounded,
                    size: 20,
                    color: c.passed ? s.primary : s.error,
                  ),
                  const SizedBox(width: Gaps.m),
                  Expanded(child: Text(c.label, style: t.bodyMedium)),
                ],
              ),
            ),
        ],
        for (final n in notes) ...[const SizedBox(height: Gaps.m), MessageBanner(message: n, kind: BannerKind.warning)],
        if (result.copyText != null && result.copyText!.isNotEmpty) ...[
          const SizedBox(height: Gaps.xl),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gaps.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Text', style: t.titleSmall)),
                      TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: result.copyText!));
                          showMessage(context, 'Copied to clipboard');
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('Copy'),
                      ),
                    ],
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: SingleChildScrollView(child: SelectableText(result.copyText!, style: t.bodyMedium)),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (saved.isNotEmpty) ...[
          const SizedBox(height: Gaps.xl),
          Text(
            saved.length == 1 ? 'Saved to SnapPDF files' : '${saved.length} files saved to SnapPDF files',
            style: t.titleSmall,
          ),
          const SizedBox(height: Gaps.s),
          for (final e in saved) _OutputCard(entry: e, path: store.fileOf(e).path),
          if (saved.length > 1) ...[
            const SizedBox(height: Gaps.s),
            OutlinedButton.icon(
              onPressed: () => exportEntries(context, ref, saved),
              icon: const Icon(Icons.drive_folder_upload_outlined),
              label: const Text('Save all to a folder'),
            ),
            const SizedBox(height: Gaps.s),
            OutlinedButton.icon(
              onPressed: () =>
                  ref.read(nativeApiProvider).share([for (final e in saved) store.fileOf(e).path], _commonMime(saved)),
              icon: const Icon(Icons.share_outlined),
              label: const Text('Share all'),
            ),
          ],
        ],
        const SizedBox(height: Gaps.xl),
        TextButton.icon(onPressed: onAgain, icon: const Icon(Icons.refresh_rounded), label: const Text('Start over')),
      ],
    );
  }
}

String _commonMime(List<LibraryEntry> entries) {
  final kinds = entries.map((e) => e.kind).toSet();
  if (kinds.length == 1) {
    return switch (kinds.first) {
      FileKind.pdf => 'application/pdf',
      FileKind.image => 'image/*',
      FileKind.text => 'text/plain',
      FileKind.other => '*/*',
    };
  }
  return '*/*';
}

class _OutputCard extends ConsumerWidget {
  const _OutputCard({required this.entry, required this.path});
  final LibraryEntry entry;
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final api = ref.read(nativeApiProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gaps.s),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gaps.l, Gaps.l, Gaps.s, Gaps.s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  FileThumb(name: entry.name, path: path, size: 52),
                  const SizedBox(width: Gaps.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.name, style: t.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(formatBytes(entry.size), style: t.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gaps.s),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () => openEntry(context, entry),
                    icon: const Icon(Icons.visibility_outlined, size: 18),
                    label: const Text('Open'),
                  ),
                  TextButton.icon(
                    onPressed: () => saveEntryToDevice(context, ref, entry),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Save to device'),
                  ),
                  TextButton.icon(
                    onPressed: () => api.share([path], entry.mime),
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('Share'),
                  ),
                  TextButton.icon(
                    onPressed: () => context.push('/continue', extra: entry),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: const Text('Continue'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens a library entry in the appropriate viewer.
void openEntry(BuildContext context, LibraryEntry entry) {
  switch (entry.kind) {
    case FileKind.pdf:
      context.push('/viewer', extra: entry);
    case FileKind.image:
      context.push('/image-viewer', extra: entry);
    case FileKind.text:
      context.push('/text-viewer', extra: entry);
    case FileKind.other:
      showMessage(context, 'This file type cannot be previewed.');
  }
}

Future<void> saveEntryToDevice(BuildContext context, WidgetRef ref, LibraryEntry entry) async {
  final api = ref.read(nativeApiProvider);
  final store = ref.read(libraryStoreProvider);
  try {
    final uri = await api.saveAs(store.fileOf(entry).path, entry.name, entry.mime);
    if (uri != null) {
      await ref.read(libraryProvider.notifier).mutate((s) => s.recordHistory(entry.id, 'Saved to device'));
      if (context.mounted) showMessage(context, 'Saved “${entry.name}”');
    }
  } on NativeError catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
}

Future<void> exportEntries(BuildContext context, WidgetRef ref, List<LibraryEntry> entries) async {
  final api = ref.read(nativeApiProvider);
  final store = ref.read(libraryStoreProvider);
  try {
    final folder = await api.pickFolder();
    if (folder == null) return;
    final names = await api.exportToFolder(folder.uri, [
      for (final e in entries) (path: store.fileOf(e).path, name: e.name),
    ]);
    if (context.mounted) {
      showMessage(context, 'Saved ${names.length} file(s) to ${folder.name ?? 'the folder'}');
    }
  } on NativeError catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
}

/// Basic checks shared by PDF tools: reopen and count pages.
Future<List<Check>> verifyPdf(NativeApi api, String path, {int? expectedPages, String? password}) async {
  try {
    final info = await api.pdfInfo(path, password: password);
    return [
      const Check('Output opens as a valid PDF', true),
      if (expectedPages != null)
        Check(
          '$expectedPages page${expectedPages == 1 ? '' : 's'} (found ${info.pageCount})',
          info.pageCount == expectedPages,
        ),
    ];
  } on NativeError catch (e) {
    return [Check('Output could not be reopened: ${e.message}', false)];
  }
}

Future<int> fileSize(String path) => File(path).length();

/// Card listing selected inputs with add/remove (and optional reordering).
class InputsCard extends ConsumerWidget {
  const InputsCard({
    super.key,
    required this.inputs,
    required this.accept,
    required this.onChanged,
    this.multiple = false,
    this.reorderable = false,
    this.emptyLabel,
    this.onAdded,
    this.subtitleFor,
  });

  final List<InputFile> inputs;
  final Accept accept;
  final bool multiple;
  final bool reorderable;
  final String? emptyLabel;
  final ValueChanged<List<InputFile>> onChanged;

  /// Called with newly added inputs (e.g. to probe PDFs) before onChanged.
  final Future<List<InputFile>> Function(List<InputFile> added)? onAdded;
  final String Function(InputFile input)? subtitleFor;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    var picked = await pickInputs(context, ref, accept: accept, multiple: multiple);
    if (picked.isEmpty) return;
    if (onAdded != null) picked = await onAdded!(picked);
    if (picked.isEmpty) return;
    onChanged(multiple ? [...inputs, ...picked] : [picked.first]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    if (inputs.isEmpty) {
      return Card(
        child: InkWell(
          onTap: () => _add(context, ref),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gaps.xxl, horizontal: Gaps.l),
            child: Column(
              children: [
                const ToneIcon(Icons.add_rounded, size: 52),
                const SizedBox(height: Gaps.m),
                Text(
                  emptyLabel ?? (multiple ? 'Add ${accept.label} files' : 'Choose a ${accept.label}'),
                  style: t.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text('Your original files are never changed', style: t.bodySmall, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }

    Widget tile(int i) {
      final f = inputs[i];
      return ListTile(
        key: ValueKey('${f.path}#$i'),
        contentPadding: const EdgeInsets.only(left: Gaps.l, right: Gaps.xs),
        leading: FileThumb(name: f.name, path: f.path, size: 44),
        title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitleFor?.call(f) ?? formatBytes(f.size)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Remove ${f.name}',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => onChanged([...inputs]..removeAt(i)),
            ),
            if (reorderable && inputs.length > 1)
              ReorderableDragStartListener(
                index: i,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.drag_indicator_rounded, semanticLabel: 'Reorder'),
                ),
              ),
          ],
        ),
      );
    }

    return Card(
      child: Column(
        children: [
          if (reorderable)
            ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: inputs.length,
              onReorderItem: (a, b) {
                final list = [...inputs];
                final item = list.removeAt(a);
                list.insert(b, item);
                onChanged(list);
              },
              itemBuilder: (_, i) => tile(i),
            )
          else
            for (var i = 0; i < inputs.length; i++) tile(i),
          if (multiple || inputs.isEmpty) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: Text(multiple ? 'Add more' : 'Choose file'),
              onTap: () => _add(context, ref),
            ),
          ] else ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.swap_horiz_rounded),
              title: const Text('Choose a different file'),
              onTap: () => _add(context, ref),
            ),
          ],
        ],
      ),
    );
  }
}
