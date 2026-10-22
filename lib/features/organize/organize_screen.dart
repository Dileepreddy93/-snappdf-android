import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import '../pdf/pdf_common.dart';
import 'organizer_model.dart';

class _Source {
  _Source(this.input, this.info, this.document);
  final InputFile input;
  final PdfInfo info;
  final PdfDocument document;
}

/// Visual page organizer: reorder, rotate, duplicate, delete, crop and
/// insert pages, with undo/redo. Saves a new PDF; the original is untouched.
class OrganizeScreen extends ConsumerStatefulWidget {
  const OrganizeScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<OrganizeScreen> createState() => _OrganizeScreenState();
}

class _OrganizeScreenState extends ConsumerState<OrganizeScreen> {
  final List<_Source> _sources = [];
  OrganizerModel? _model;
  final Set<int> _selected = {};
  bool _busy = false;
  double? _progress;
  String? _error;

  NativeApi get _api => ref.read(nativeApiProvider);

  @override
  void initState() {
    super.initState();
    final pdf = widget.initial.where((f) => f.kind == FileKind.pdf).firstOrNull;
    if (pdf != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openMain(pdf));
    }
  }

  @override
  void dispose() {
    for (final s in _sources) {
      unawaited(s.document.dispose());
    }
    super.dispose();
  }

  Future<_Source?> _openSource(InputFile f) async {
    final info = await probePdf(context, _api, f);
    if (info == null) return null;
    final doc = await PdfDocument.openFile(f.path, passwordProvider: createSimplePasswordProvider(f.password));
    return _Source(f, info, doc);
  }

  Future<void> _openMain(InputFile f) async {
    try {
      final src = await _openSource(f);
      if (src == null || !mounted) return;
      setState(() {
        _sources.add(src);
        _model = OrganizerModel(src.info.pageCount);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _pickMain() async {
    final picked = await pickInputs(context, ref, accept: Accept.pdf);
    if (picked.isNotEmpty) await _openMain(picked.first);
  }

  int get _insertAt {
    final m = _model!;
    if (_selected.isEmpty) return m.length;
    final idx = m.pages.lastIndexWhere((p) => _selected.contains(p.id));
    return idx + 1;
  }

  Future<void> _addMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: const Text('Blank page'),
              subtitle: const Text('Same size as the neighbouring page'),
              onTap: () => Navigator.pop(context, 'blank'),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('Pages from another PDF'),
              onTap: () => Navigator.pop(context, 'pdf'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Images as pages'),
              onTap: () => Navigator.pop(context, 'images'),
            ),
            const SizedBox(height: Gaps.s),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final at = _insertAt;
    switch (choice) {
      case 'blank':
        final ref0 = _model!.pages.isEmpty ? null : _model!.pages[(at - 1).clamp(0, _model!.length - 1)];
        var w = 595.0, h = 842.0;
        if (ref0 != null) {
          if (ref0.isBlank) {
            w = ref0.blankWidth!;
            h = ref0.blankHeight!;
          } else {
            final ps = _sources[ref0.source].info.pages[ref0.index];
            final swap = (ref0.rotate ~/ 90).isOdd;
            w = swap ? ps.height : ps.width;
            h = swap ? ps.width : ps.height;
          }
        }
        setState(() => _model!.insertBlank(at, w, h));
      case 'pdf':
        final picked = await pickInputs(context, ref, accept: Accept.pdf);
        if (picked.isEmpty || !mounted) return;
        final src = await _openSource(picked.first);
        if (src == null) return;
        setState(() {
          _sources.add(src);
          _model!.insertSource(_sources.length - 1, src.info.pageCount, at);
        });
      case 'images':
        final images = await pickInputs(context, ref, accept: Accept.image, multiple: true);
        if (images.isEmpty || !mounted) return;
        setState(() => _busy = true);
        try {
          final out = await ref.read(workspaceProvider).newWorkFile('images.pdf');
          await _api.imagesToPdf([for (final i in images) i.path], out);
          final input = InputFile(path: out, name: 'Images', size: 0);
          final src = await _openSource(input);
          if (src != null && mounted) {
            setState(() {
              _sources.add(src);
              _model!.insertSource(_sources.length - 1, src.info.pageCount, at);
            });
          }
        } on NativeError catch (e) {
          if (mounted) showMessage(context, e.message);
        } finally {
          if (mounted) setState(() => _busy = false);
        }
    }
  }

  Future<void> _crop() async {
    final result = await showDialog<List<double>?>(context: context, builder: (context) => const _CropDialog());
    if (result == null) return;
    setState(() => _model!.setCrop(_selected, result.every((v) => v == 0) ? null : result));
  }

  Future<void> _save({bool selectionOnly = false}) async {
    final model = _model!;
    final main = _sources.first.input;
    final ws = ref.read(workspaceProvider);
    final name = derivedName(main.name, selectionOnly ? 'extract' : 'organized', extension: 'pdf');
    final out = await ws.newWorkFile(name);
    final pages = model.toArgs(selectionOnly ? _selected : null);
    setState(() {
      _busy = true;
      _error = null;
      _progress = null;
    });
    try {
      await withOwnerPassword(
        this,
        main,
        () => _api.assemble([for (final s in _sources) (path: s.input.path, password: s.input.password)], pages, out),
      );
      final checks = await verifyPdf(_api, out, expectedPages: pages.length);
      final r = await ref
          .read(libraryProvider.notifier)
          .addOutput(out, name, action: selectionOnly ? 'Extract pages' : 'Organize pages');
      if (!mounted) return;
      final ok = checks.every((c) => c.passed);
      showMessage(
        context,
        ok ? 'Saved “$name” (${pages.length} pages)' : 'Saved, but verification failed',
        action: SnackBarAction(label: 'Open', onPressed: () => openEntry(context, r.entry)),
      );
      if (!selectionOnly) context.pop();
    } on NativeError catch (e) {
      if (mounted && !e.isCancelled) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    if (model == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Organize pages')),
        body: _error != null
            ? Padding(
                padding: const EdgeInsets.all(Gaps.page),
                child: MessageBanner(kind: BannerKind.error, message: _error!),
              )
            : EmptyState(
                icon: Icons.grid_view_rounded,
                title: 'Reorder, rotate and delete pages',
                message: 'Choose a PDF to see its pages.',
                action: FilledButton.icon(
                  onPressed: _pickMain,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Choose PDF'),
                ),
              ),
      );
    }
    final selecting = _selected.isNotEmpty;
    final width = MediaQuery.sizeOf(context).width;
    final columns = width > 900
        ? 5
        : width > 600
        ? 4
        : width < 360
        ? 2
        : 3;
    return PopScope(
      canPop: !model.isModified || _busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard changes?'),
            content: const Text('Your page changes have not been saved.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
            ],
          ),
        );
        if (discard == true && context.mounted) context.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(selecting ? '${_selected.length} selected' : 'Organize pages'),
          leading: selecting
              ? IconButton(
                  tooltip: 'Clear selection',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(_selected.clear),
                )
              : null,
          actions: [
            IconButton(
              tooltip: 'Undo',
              icon: const Icon(Icons.undo_rounded),
              onPressed: model.canUndo ? () => setState(model.undo) : null,
            ),
            IconButton(
              tooltip: 'Redo',
              icon: const Icon(Icons.redo_rounded),
              onPressed: model.canRedo ? () => setState(model.redo) : null,
            ),
            IconButton(
              tooltip: selecting ? 'Insert after selection' : 'Add pages',
              icon: const Icon(Icons.add_rounded),
              onPressed: _busy ? null : _addMenu,
            ),
          ],
        ),
        body: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gaps.page, 0, Gaps.page, Gaps.s),
                child: MessageBanner(kind: BannerKind.error, message: _error!),
              ),
            if (_busy) LinearProgressIndicator(value: _progress),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.xs, Gaps.page, Gaps.s),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${pages(model.length)} · tap to select, long-press and drag to move',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      if (_selected.length == model.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(model.pages.map((p) => p.id));
                      }
                    }),
                    child: Text(_selected.length == model.length ? 'Select none' : 'Select all'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(Gaps.l, 0, Gaps.l, Gaps.xl),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: Gaps.m,
                  crossAxisSpacing: Gaps.m,
                  childAspectRatio: 0.72,
                ),
                itemCount: model.length,
                itemBuilder: (context, i) => _buildCell(i, model.pages[i]),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gaps.s, Gaps.xs, Gaps.page, Gaps.m),
            child: selecting
                ? Row(
                    children: [
                      IconButton(
                        tooltip: 'Rotate left',
                        icon: const Icon(Icons.rotate_left_rounded),
                        onPressed: () => setState(() => model.rotate(_selected, -90)),
                      ),
                      IconButton(
                        tooltip: 'Rotate right',
                        icon: const Icon(Icons.rotate_right_rounded),
                        onPressed: () => setState(() => model.rotate(_selected, 90)),
                      ),
                      IconButton(
                        tooltip: 'Duplicate',
                        icon: const Icon(Icons.copy_all_outlined),
                        onPressed: () => setState(() => model.duplicate(_selected)),
                      ),
                      IconButton(tooltip: 'Crop', icon: const Icon(Icons.crop_rounded), onPressed: _crop),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () {
                          if (_selected.length >= model.length) {
                            showMessage(context, 'A PDF needs at least one page.');
                            return;
                          }
                          setState(() {
                            model.delete(_selected);
                            _selected.clear();
                          });
                        },
                      ),
                      const Spacer(),
                      FilledButton.tonal(
                        onPressed: _busy ? null : () => _save(selectionOnly: true),
                        child: const Text('Extract'),
                      ),
                    ],
                  )
                : FilledButton.icon(
                    onPressed: _busy || !model.isModified ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(model.isModified ? 'Save as new PDF' : 'No changes yet'),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildCell(int i, OrgPage page) {
    final selected = _selected.contains(page.id);
    final cell = _PageCell(
      key: ValueKey(page.id),
      page: page,
      number: i + 1,
      selected: selected,
      sources: _sources,
      onTap: () => setState(() => selected ? _selected.remove(page.id) : _selected.add(page.id)),
    );
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != i,
      onAcceptWithDetails: (d) => setState(() => _model!.move(d.data, i)),
      builder: (context, candidate, _) => LongPressDraggable<int>(
        data: i,
        feedback: SizedBox(
          width: 110,
          height: 150,
          child: Opacity(
            opacity: 0.85,
            child: Material(type: MaterialType.transparency, child: cell),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: cell),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.m),
            border: Border.all(
              color: candidate.isNotEmpty ? Theme.of(context).colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: cell,
        ),
      ),
    );
  }
}

class _PageCell extends StatelessWidget {
  const _PageCell({
    super.key,
    required this.page,
    required this.number,
    required this.selected,
    required this.sources,
    required this.onTap,
  });

  final OrgPage page;
  final int number;
  final bool selected;
  final List<_Source> sources;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final label = page.isBlank
        ? 'Blank'
        : page.source == 0
        ? 'p. ${page.index + 1}'
        : '${sources[page.source].input.name.length > 10 ? '${sources[page.source].input.name.substring(0, 10)}…' : sources[page.source].input.name} p. ${page.index + 1}';
    Widget thumb;
    if (page.isBlank) {
      final swap = (page.rotate ~/ 90).isOdd;
      thumb = AspectRatio(
        aspectRatio: swap ? page.blankHeight! / page.blankWidth! : page.blankWidth! / page.blankHeight!,
        child: Container(color: Colors.white),
      );
    } else {
      final src = sources[page.source];
      final base = src.info.pages[page.index].rotation;
      final rotation = PdfPageRotation.values[(((base + page.rotate) ~/ 90) % 4 + 4) % 4];
      // pdfrx renders with the page's own rotation; override with the combined value.
      thumb = PdfPageView(
        document: src.document,
        pageNumber: page.index + 1,
        rotationOverride: rotation,
        maximumDpi: 72,
        backgroundColor: Colors.white,
      );
    }
    return Semantics(
      button: true,
      selected: selected,
      label: 'Page $number, $label${page.rotate != 0 ? ', rotated ${page.rotate} degrees' : ''}',
      child: Material(
        color: selected ? s.secondaryContainer : s.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.m),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.m),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Gaps.s),
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.12),
                                  blurRadius: 4,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                            child: thumb,
                          ),
                        ),
                      ),
                      if (page.crop != null)
                        const Positioned(left: 4, bottom: 4, child: Pill('Cropped', icon: Icons.crop_rounded)),
                      if (selected)
                        Positioned(
                          right: 2,
                          top: 2,
                          child: CircleAvatar(
                            radius: 13,
                            backgroundColor: s.primary,
                            child: Icon(Icons.check_rounded, size: 16, color: s.onPrimary),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Gaps.xs),
                Text('$number', style: t.labelLarge),
                Text(label, style: t.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CropDialog extends StatefulWidget {
  const _CropDialog();

  @override
  State<_CropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<_CropDialog> {
  final _m = [0.0, 0.0, 0.0, 0.0];
  static const _labels = ['Left', 'Top', 'Right', 'Bottom'];

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Crop pages'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 0.75,
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                children: [
                  Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                  Positioned(
                    left: c.maxWidth * _m[0],
                    top: c.maxHeight * _m[1],
                    right: c.maxWidth * _m[2],
                    bottom: c.maxHeight * _m[3],
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gaps.m),
          for (var i = 0; i < 4; i++)
            LabeledSlider(
              label: _labels[i],
              value: _m[i],
              min: 0,
              max: 0.4,
              format: (v) => '${(v * 100).round()}%',
              onChanged: (v) => setState(() => _m[i] = v),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, [0.0, 0.0, 0.0, 0.0]), child: const Text('Remove crop')),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, List<double>.from(_m)), child: const Text('Apply')),
    ],
  );
}
