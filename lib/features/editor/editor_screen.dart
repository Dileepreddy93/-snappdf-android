import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:pdfrx/pdfrx.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/files/library_store.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import '../image/image_io.dart';
import '../signature/signature_pad.dart';
import '../signature/signature_picker.dart';
import 'editor_model.dart';

enum EditorMode { edit, sign, redact }

enum Tool {
  hand(Icons.pan_tool_outlined, 'Move & zoom'),
  select(Icons.near_me_outlined, 'Select'),
  text(Icons.text_fields_rounded, 'Text'),
  ink(Icons.gesture_rounded, 'Draw'),
  highlight(Icons.highlight_rounded, 'Highlight'),
  underline(Icons.format_underline_rounded, 'Underline'),
  strikeout(Icons.strikethrough_s_rounded, 'Strike'),
  note(Icons.sticky_note_2_outlined, 'Comment'),
  signature(Icons.draw_outlined, 'Signature'),
  image(Icons.add_photo_alternate_outlined, 'Image'),
  stamp(Icons.approval_outlined, 'Stamp'),
  date(Icons.event_outlined, 'Date'),
  redact(Icons.format_color_fill_rounded, 'Redact');

  const Tool(this.icon, this.label);
  final IconData icon;
  final String label;
}

const _inkPalette = [0xFF0B1F4D, 0xFF111111, 0xFFD32F2F, 0xFF1565C0, 0xFF2E7D32];
const _markPalette = [0xFFFFEB3B, 0xFF81C784, 0xFF64B5F6, 0xFFF48FB1, 0xFFE53935];
const _stamps = ['APPROVED', 'DRAFT', 'CONFIDENTIAL', 'PAID', 'RECEIVED', 'REJECTED', 'COPY', 'VERIFIED'];

(Size, double) measureText(String text, double fontSize, bool bold) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'NotoSans',
        fontSize: fontSize,
        height: kTextLineHeight,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final baseline = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
  final size = tp.size;
  tp.dispose();
  return (size, baseline);
}

enum _Drag { none, move, resize, create }

/// Editor for annotations, signatures and redaction. Saves a new PDF; the
/// original is never modified.
class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key, this.initial = const [], this.mode = EditorMode.edit});
  final List<InputFile> initial;
  final EditorMode mode;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  InputFile? _input;
  PdfInfo? _info;
  PdfDocument? _doc;
  int _page = 0;
  late Tool _tool = widget.mode == EditorMode.redact ? Tool.redact : Tool.select;
  final _model = EditorModel();
  int? _selectedId;
  final _tc = TransformationController();

  // Live interaction state (points).
  _Drag _drag = _Drag.none;
  EditItem? _live;
  Offset? _dragOrigin;
  Offset? _dragLast;
  List<Offset>? _liveStroke;

  int _inkColor = _inkPalette.first;
  double _inkWidth = 2;
  int _markColor = _markPalette.first;
  bool _flatten = false;
  bool _saving = false;
  String? _error;

  NativeApi get _api => ref.read(nativeApiProvider);

  @override
  void initState() {
    super.initState();
    final pdf = widget.initial.where((f) => f.kind == FileKind.pdf).firstOrNull;
    if (pdf != null) WidgetsBinding.instance.addPostFrameCallback((_) => _open(pdf));
  }

  @override
  void dispose() {
    unawaited(_doc?.dispose());
    _tc.dispose();
    super.dispose();
  }

  Future<void> _open(InputFile f) async {
    try {
      final info = await probePdf(context, _api, f);
      if (info == null || !mounted) return;
      final doc = await PdfDocument.openFile(f.path, passwordProvider: createSimplePasswordProvider(f.password));
      if (!mounted) {
        await doc.dispose();
        return;
      }
      setState(() {
        _input = f;
        _info = info;
        _doc = doc;
      });
      if (widget.mode == EditorMode.sign) await _placeSignature();
    } on NativeError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'This PDF could not be opened: $e');
    }
  }

  Size get _pageSize {
    final p = _info!.pages[_page];
    return Size(p.width, p.height);
  }

  List<Tool> get _tools => switch (widget.mode) {
    EditorMode.redact => const [Tool.redact, Tool.select, Tool.hand],
    EditorMode.sign => const [Tool.signature, Tool.date, Tool.text, Tool.select, Tool.hand],
    EditorMode.edit => const [
      Tool.select,
      Tool.hand,
      Tool.text,
      Tool.ink,
      Tool.highlight,
      Tool.underline,
      Tool.strikeout,
      Tool.note,
      Tool.signature,
      Tool.image,
      Tool.stamp,
      Tool.date,
    ],
  };

  EditItem? get _selected => _selectedId == null ? null : _model.byId(_selectedId!);

  void _select(EditItem? item) => setState(() => _selectedId = item?.id);

  Future<void> _onToolTap(Tool tool) async {
    switch (tool) {
      case Tool.signature:
        await _placeSignature();
      case Tool.image:
        await _placeImage();
      case Tool.stamp:
        await _placeStamp();
      case Tool.date:
        _addText(DateFormat.yMMMd().format(DateTime.now()), _centerOf(const Size(120, 16)));
      default:
        setState(() {
          _tool = tool;
          if (tool != Tool.select) _selectedId = null;
        });
    }
  }

  Offset _centerOf(Size s) => Offset((_pageSize.width - s.width) / 2, (_pageSize.height - s.height) / 2);

  Future<void> _placeSignature() async {
    final path = await pickSignature(context, ref);
    if (path == null || !mounted) return;
    final img = await decodeImageFromList(await File(path).readAsBytes());
    final w = _pageSize.width * 0.3;
    final h = w * img.height / img.width;
    img.dispose();
    final rect = _centerOf(Size(w, h)) & Size(w, h);
    _addItem(ImageItem(_model.newId(), _page, rect: rect, path: path, isSignature: true));
    if (mounted) showMessage(context, 'Drag to position. Use the corner handle to resize.');
  }

  Future<void> _placeImage() async {
    final picked = await pickInputs(context, ref, accept: Accept.image);
    if (picked.isEmpty || !mounted) return;
    try {
      final prepared = await prepareImageForPdf(picked.first.path, ref.read(workspaceProvider));
      final w = _pageSize.width * 0.45;
      final h = w * prepared.height / prepared.width;
      _addItem(ImageItem(_model.newId(), _page, rect: _centerOf(Size(w, h)) & Size(w, h), path: prepared.path));
    } catch (e) {
      if (mounted) showMessage(context, 'That image could not be used: $e');
    }
  }

  Future<void> _placeStamp() async {
    final custom = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add stamp'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: Gaps.s,
                runSpacing: Gaps.s,
                children: [
                  for (final s in _stamps) ActionChip(label: Text(s), onPressed: () => Navigator.pop(context, s)),
                ],
              ),
              const SizedBox(height: Gaps.l),
              TextField(
                controller: custom,
                decoration: const InputDecoration(labelText: 'Custom text'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, custom.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    final color = switch (text) {
      'APPROVED' || 'PAID' || 'VERIFIED' || 'RECEIVED' => 0xFF2E7D32,
      'REJECTED' || 'CONFIDENTIAL' => 0xFFC62828,
      _ => 0xFF1565C0,
    };
    final w = math.max(110.0, text.length * 13.0 + 36);
    const h = 44.0;
    _addItem(StampItem(_model.newId(), _page, rect: _centerOf(Size(w, h)) & Size(w, h), text: text, color: color));
  }

  void _addItem(EditItem item) {
    setState(() {
      _model.add(item);
      _selectedId = item.id;
      _tool = Tool.select;
    });
  }

  void _addText(String text, Offset at, {double fontSize = 14, int color = 0xFF111111}) {
    final (size, baseline) = measureText(text, fontSize, false);
    _addItem(
      TextItem(
        _model.newId(),
        _page,
        origin: at,
        text: text,
        fontSize: fontSize,
        color: color,
        size: size,
        baseline: baseline,
      ),
    );
  }

  Future<String?> _askText({String initial = '', String title = 'Add text'}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          decoration: const InputDecoration(labelText: 'Text'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Done')),
        ],
      ),
    );
  }

  // ---------------- Gestures (positions in points) ----------------

  Future<void> _onTap(Offset p) async {
    switch (_tool) {
      case Tool.select:
        _select(_model.hitTest(_page, p));
      case Tool.text:
        final text = await _askText();
        if (text != null && text.trim().isNotEmpty) _addText(text, p);
      case Tool.note:
        final text = await _askText(title: 'Add comment');
        if (text != null && text.trim().isNotEmpty) {
          _addItem(
            NoteItem(
              _model.newId(),
              _page,
              at: p - const Offset(NoteItem.iconSize / 2, NoteItem.iconSize / 2),
              text: text,
            ),
          );
        }
      default:
        break;
    }
  }

  bool _nearHandle(EditItem item, Offset p, double k) {
    final b = item.bounds;
    return (p - b.bottomRight).distance <= 22 / k;
  }

  bool _resizable(EditItem item) =>
      item is ImageItem || item is StampItem || item is RedactItem || item is MarkupItem || item is TextItem;

  void _onPanStart(Offset p, double k) {
    _dragOrigin = p;
    _dragLast = p;
    switch (_tool) {
      case Tool.select:
        final sel = _selected;
        if (sel != null && _resizable(sel) && _nearHandle(sel, p, k)) {
          _drag = _Drag.resize;
          _live = sel;
        } else {
          final hit = _model.hitTest(_page, p);
          if (hit != null) {
            _selectedId = hit.id;
            _drag = _Drag.move;
            _live = hit;
          } else {
            _selectedId = null;
            _drag = _Drag.none;
          }
        }
      case Tool.ink:
        _drag = _Drag.create;
        _liveStroke = [p];
      case Tool.highlight || Tool.underline || Tool.strikeout || Tool.redact:
        _drag = _Drag.create;
      default:
        _drag = _Drag.none;
    }
    setState(() {});
  }

  void _onPanUpdate(Offset p) {
    final last = _dragLast ?? p;
    final delta = p - last;
    _dragLast = p;
    switch (_drag) {
      case _Drag.move:
        _live = _live!.translated(delta);
      case _Drag.resize:
        final it = _live!;
        _live = switch (it) {
          ImageItem() => it.copyWith(rect: resizeFromCorner(it.rect, delta, aspect: it.aspect)),
          StampItem() => it.copyWith(rect: resizeFromCorner(it.rect, delta)),
          RedactItem() => it.copyWith(rect: resizeFromCorner(it.rect, delta)),
          MarkupItem() => MarkupItem(
            it.id,
            it.page,
            kind: it.kind,
            rect: resizeFromCorner(it.rect, delta),
            color: it.color,
          ),
          TextItem() => _scaledText(it, (it.size.width + delta.dx) / it.size.width),
          _ => it,
        };
      case _Drag.create:
        if (_liveStroke != null) _liveStroke!.add(p);
      case _Drag.none:
        break;
    }
    setState(() {});
  }

  TextItem _scaledText(TextItem t, double factor) {
    final size = (t.fontSize * factor).clamp(6.0, 144.0);
    final (s, baseline) = measureText(t.text, size, t.bold);
    return t.copyWith(fontSize: size, size: s, baseline: baseline);
  }

  void _onPanEnd() {
    switch (_drag) {
      case _Drag.move || _Drag.resize:
        if (_live != null) _model.replace(_live!);
      case _Drag.create:
        if (_liveStroke != null && _liveStroke!.isNotEmpty) {
          _model.add(InkItem(_model.newId(), _page, strokes: [_liveStroke!], color: _inkColor, width: _inkWidth));
        } else if (_dragOrigin != null && _dragLast != null) {
          final r = dragRect(_dragOrigin!, _dragLast!, _pageSize);
          if (r.width >= 4 && r.height >= 4) {
            final id = _model.newId();
            _model.add(switch (_tool) {
              Tool.redact => RedactItem(id, _page, rect: r),
              Tool.underline => MarkupItem(
                id,
                _page,
                kind: MarkupKind.underline,
                rect: r,
                color: _markColor == _markPalette.first ? 0xFFE53935 : _markColor,
              ),
              Tool.strikeout => MarkupItem(
                id,
                _page,
                kind: MarkupKind.strikeout,
                rect: r,
                color: _markColor == _markPalette.first ? 0xFFE53935 : _markColor,
              ),
              _ => MarkupItem(id, _page, kind: MarkupKind.highlight, rect: r, color: _markColor),
            });
          }
        }
      case _Drag.none:
        break;
    }
    setState(() {
      _drag = _Drag.none;
      _live = null;
      _liveStroke = null;
      _dragOrigin = null;
      _dragLast = null;
    });
  }

  // ---------------- Saving ----------------

  Future<void> _save() async {
    final f = _input!;
    final ws = ref.read(workspaceProvider);
    final redacting = widget.mode == EditorMode.redact;
    if (redacting) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Redact permanently?'),
          content: const Text(
            'Marked areas are blacked out and every page with a redaction is rebuilt as an image, so the hidden '
            'content is removed from the file for good. Text on those pages will no longer be selectable. '
            'Your original file is not changed.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Redact')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final suffix = switch (widget.mode) {
        EditorMode.redact => 'redacted',
        EditorMode.sign => 'signed',
        EditorMode.edit => 'edited',
      };
      final name = derivedName(f.name, suffix, extension: 'pdf');
      final out = await ws.newWorkFile(name);
      final checks = <Check>[];
      final notes = <String>[];
      if (redacting) {
        final r = await withOwnerPassword(this, f, () => _api.redact(f.path, f.password, out, _model.redactions()));
        checks.add(
          Check(
            'No text remains on the ${r.pagesRedacted} redacted page${r.pagesRedacted == 1 ? '' : 's'}',
            r.verified,
          ),
        );
        notes.add('Redacted pages are now images: their text cannot be searched or copied.');
      } else {
        await withOwnerPassword(
          this,
          f,
          () => _api.applyEdits(
            f.path,
            f.password,
            out,
            _model.toEdits(),
            flatten: _flatten,
            author: ref.read(settingsProvider).authorName,
          ),
        );
        if (_model.items.any((i) => i is ImageItem && i.isSignature)) {
          notes.add(
            'This is a visual (handwritten-style) signature. It is not a cryptographic digital signature '
            'and does not prove who signed or detect later changes.',
          );
        }
      }
      checks.addAll(await verifyPdf(_api, out, expectedPages: _info!.pageCount));
      if (f.password != null) {
        notes.add('The result is not password protected. Use “Protect PDF” to add a password again.');
      }
      final saved = await ref
          .read(libraryProvider.notifier)
          .addOutput(
            out,
            name,
            action: switch (widget.mode) {
              EditorMode.redact => 'Redact',
              EditorMode.sign => 'Sign',
              EditorMode.edit => 'Edit',
            },
          );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ResultPage(
            title: switch (widget.mode) {
              EditorMode.redact => 'Redact',
              EditorMode.sign => 'Sign PDF',
              EditorMode.edit => 'Edit PDF',
            },
            result: ToolResult(
              headline: switch (widget.mode) {
                EditorMode.redact => 'Redacted and saved',
                EditorMode.sign => 'Signed and saved',
                EditorMode.edit => 'Changes saved',
              },
              checks: checks,
              notes: notes,
            ),
            saved: [saved.entry],
          ),
        ),
      );
    } on NativeError catch (e) {
      if (mounted && !e.isCancelled) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.mode) {
      EditorMode.redact => 'Redact',
      EditorMode.sign => 'Sign PDF',
      EditorMode.edit => 'Edit PDF',
    };
    if (_input == null || _doc == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: _error != null
            ? Padding(
                padding: const EdgeInsets.all(Gaps.page),
                child: MessageBanner(kind: BannerKind.error, message: _error!),
              )
            : EmptyState(
                icon: widget.mode == EditorMode.redact ? Icons.format_color_fill_rounded : Icons.edit_document,
                title: switch (widget.mode) {
                  EditorMode.redact => 'Permanently remove sensitive content',
                  EditorMode.sign => 'Sign a PDF',
                  EditorMode.edit => 'Annotate and add content',
                },
                message: widget.mode == EditorMode.edit
                    ? 'Add text, drawings, highlights, comments, images and stamps. Existing text in the PDF cannot be edited.'
                    : null,
                action: FilledButton.icon(
                  onPressed: () async {
                    final picked = await pickInputs(context, ref, accept: Accept.pdf);
                    if (picked.isNotEmpty) await _open(picked.first);
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Choose PDF'),
                ),
              ),
      );
    }
    final hasChanges = widget.mode == EditorMode.redact
        ? _model.items.whereType<RedactItem>().isNotEmpty
        : !_model.isEmpty;
    return PopScope(
      canPop: !hasChanges || _saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard changes?'),
            content: const Text('Your changes have not been saved.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
            ],
          ),
        );
        if (discard == true && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            IconButton(
              tooltip: 'Undo',
              icon: const Icon(Icons.undo_rounded),
              onPressed: _model.canUndo
                  ? () => setState(() {
                      _model.undo();
                      _selectedId = null;
                    })
                  : null,
            ),
            IconButton(
              tooltip: 'Redo',
              icon: const Icon(Icons.redo_rounded),
              onPressed: _model.canRedo
                  ? () => setState(() {
                      _model.redo();
                      _selectedId = null;
                    })
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.only(right: Gaps.s),
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(72, 40)),
                onPressed: hasChanges && !_saving ? _save : null,
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(widget.mode == EditorMode.redact ? 'Redact' : 'Save'),
              ),
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
            if (widget.mode == EditorMode.redact && _model.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(Gaps.page, 0, Gaps.page, Gaps.s),
                child: MessageBanner(
                  message: 'Drag over the areas you want to remove. Use Move & zoom to look closer.',
                ),
              ),
            Expanded(child: _canvas()),
            if (_selected != null && _tool == Tool.select) _selectionPanel(_selected!),
            if (_selected == null &&
                (_tool == Tool.ink || _tool == Tool.highlight || _tool == Tool.underline || _tool == Tool.strikeout))
              _toolOptions(),
            _toolbar(),
            _pageBar(),
          ],
        ),
      ),
    );
  }

  Widget _canvas() {
    final s = Theme.of(context).colorScheme;
    return Container(
      color: s.surfaceContainer,
      child: LayoutBuilder(
        builder: (context, c) {
          final ps = _pageSize;
          final k = math.min((c.maxWidth - 24) / ps.width, (c.maxHeight - 24) / ps.height);
          final cw = ps.width * k;
          final ch = ps.height * k;
          final handTool = _tool == Tool.hand;
          Offset toPt(Offset local) => Offset((local.dx / k).clamp(0, ps.width), (local.dy / k).clamp(0, ps.height));
          final items = [
            for (final i in _model.onPage(_page))
              if (_live != null && i.id == _live!.id) _live! else i,
          ];
          return InteractiveViewer(
            transformationController: _tc,
            panEnabled: handTool,
            scaleEnabled: handTool,
            minScale: 1,
            maxScale: 6,
            boundaryMargin: const EdgeInsets.all(120),
            child: Center(
              child: SizedBox(
                width: cw,
                height: ch,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: PdfPageView(
                          document: _doc,
                          pageNumber: _page + 1,
                          maximumDpi: 300,
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                    for (final i in items) ..._itemWidgets(i, k),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _OverlayPainter(
                            items: items,
                            k: k,
                            selected: _tool == Tool.select ? (_live ?? _selected) : null,
                            showHandle: _selected != null && _resizable(_live ?? _selected!),
                            liveStroke: _liveStroke,
                            liveStrokeColor: Color(_inkColor),
                            liveStrokeWidth: _inkWidth,
                            liveRect:
                                _drag == _Drag.create && _liveStroke == null && _dragOrigin != null && _dragLast != null
                                ? dragRect(_dragOrigin!, _dragLast!, ps)
                                : null,
                            liveRectRedact: _tool == Tool.redact,
                            primary: s.primary,
                          ),
                        ),
                      ),
                    ),
                    if (!handTool)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (d) => _onTap(toPt(d.localPosition)),
                          onPanStart: (d) => _onPanStart(toPt(d.localPosition), k),
                          onPanUpdate: (d) => _onPanUpdate(toPt(d.localPosition)),
                          onPanEnd: (_) => _onPanEnd(),
                          onPanCancel: _onPanEnd,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _itemWidgets(EditItem item, double k) {
    switch (item) {
      case TextItem():
        return [
          Positioned(
            left: item.origin.dx * k,
            top: item.origin.dy * k,
            child: Text(
              item.text,
              softWrap: false,
              style: TextStyle(
                fontFamily: 'NotoSans',
                fontSize: item.fontSize * k,
                height: kTextLineHeight,
                color: Color(item.color),
                fontWeight: item.bold ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ];
      case ImageItem():
        return [
          Positioned(
            left: item.rect.left * k,
            top: item.rect.top * k,
            width: item.rect.width * k,
            height: item.rect.height * k,
            child: Transform.rotate(
              angle: item.rotation * math.pi / 180,
              child: Image.file(File(item.path), fit: BoxFit.fill, gaplessPlayback: true),
            ),
          ),
        ];
      case StampItem():
        return [
          Positioned(
            left: item.rect.left * k,
            top: item.rect.top * k,
            width: item.rect.width * k,
            height: item.rect.height * k,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Color(item.color), width: (item.rect.height * 0.06).clamp(1.0, 4.0) * k),
              ),
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(horizontal: 4 * k),
              child: FittedBox(
                child: Text(
                  item.text.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'NotoSans',
                    fontWeight: FontWeight.w700,
                    color: Color(item.color),
                    fontSize: item.rect.height * 0.55 * k,
                  ),
                ),
              ),
            ),
          ),
        ];
      case NoteItem():
        return [
          Positioned(
            left: item.at.dx * k,
            top: item.at.dy * k,
            child: Icon(Icons.sticky_note_2_rounded, size: NoteItem.iconSize * k, color: Color(item.color)),
          ),
        ];
      default:
        return const [];
    }
  }

  Widget _selectionPanel(EditItem item) {
    final t = Theme.of(context).textTheme;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gaps.m, vertical: Gaps.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(switch (item) {
                TextItem() => 'Text · ${item.fontSize.round()} pt',
                ImageItem() => item.isSignature ? 'Signature' : 'Image',
                InkItem() => 'Drawing',
                MarkupItem() => item.kind.name[0].toUpperCase() + item.kind.name.substring(1),
                NoteItem() => 'Comment',
                StampItem() => 'Stamp',
                RedactItem() => 'Redaction area',
              }, style: t.titleSmall),
            ),
            if (item is TextItem || item is NoteItem)
              IconButton(
                tooltip: 'Edit text',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final text = await _askText(
                    initial: item is TextItem ? item.text : (item as NoteItem).text,
                    title: 'Edit',
                  );
                  if (text == null || text.trim().isEmpty) return;
                  setState(() {
                    if (item is TextItem) {
                      final (size, baseline) = measureText(text, item.fontSize, item.bold);
                      _model.replace(item.copyWith(text: text, size: size, baseline: baseline));
                    } else if (item is NoteItem) {
                      _model.replace(item.withText(text));
                    }
                  });
                },
              ),
            if (item is TextItem) ...[
              IconButton(
                tooltip: 'Bold',
                isSelected: item.bold,
                icon: const Icon(Icons.format_bold_rounded),
                onPressed: () => setState(() {
                  final (size, baseline) = measureText(item.text, item.fontSize, !item.bold);
                  _model.replace(item.copyWith(bold: !item.bold, size: size, baseline: baseline));
                }),
              ),
              IconButton(
                tooltip: 'Text colour',
                icon: Icon(Icons.circle, color: Color(item.color)),
                onPressed: () => setState(() {
                  final next = _inkPalette[(_inkPalette.indexOf(item.color) + 1) % _inkPalette.length];
                  _model.replace(item.copyWith(color: next));
                }),
              ),
            ],
            if (item is ImageItem)
              IconButton(
                tooltip: 'Rotate 90 degrees',
                icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
                onPressed: () => setState(() => _model.replace(item.copyWith(rotation: (item.rotation + 90) % 360))),
              ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => setState(() {
                _model.remove(item.id);
                _selectedId = null;
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolOptions() {
    final palette = _tool == Tool.ink ? _inkPalette : _markPalette;
    final current = _tool == Tool.ink ? _inkColor : _markColor;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gaps.l, vertical: Gaps.xs),
        child: Row(
          children: [
            for (final c in palette)
              Padding(
                padding: const EdgeInsets.only(right: Gaps.s),
                child: Semantics(
                  button: true,
                  selected: c == current,
                  label: 'Colour',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _tool == Tool.ink ? _inkColor = c : _markColor = c),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == current ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_tool == Tool.ink)
              Expanded(
                child: Slider(
                  value: _inkWidth,
                  min: 0.5,
                  max: 8,
                  label: 'Thickness',
                  semanticFormatterCallback: (v) => 'Thickness ${v.toStringAsFixed(1)}',
                  onChanged: (v) => setState(() => _inkWidth = v),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    final s = Theme.of(context).colorScheme;
    return Container(
      color: s.surfaceContainerLowest,
      height: 76,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gaps.s, vertical: Gaps.s),
        children: [
          for (final tool in _tools)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _ToolButton(
                tool: tool,
                selected:
                    _tool == tool &&
                    tool != Tool.signature &&
                    tool != Tool.image &&
                    tool != Tool.stamp &&
                    tool != Tool.date,
                onTap: () => _onToolTap(tool),
              ),
            ),
          if (widget.mode == EditorMode.edit) ...[
            const VerticalDivider(),
            Center(
              child: Row(
                children: [
                  Switch(value: _flatten, onChanged: (v) => setState(() => _flatten = v)),
                  const Text('Flatten'),
                  const SizedBox(width: Gaps.m),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pageBar() {
    final count = _info!.pageCount;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 48,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Previous page',
              icon: const Icon(Icons.chevron_left_rounded),
              onPressed: _page > 0
                  ? () => setState(() {
                      _page--;
                      _selectedId = null;
                      _tc.value = Matrix4.identity();
                    })
                  : null,
            ),
            Text('Page ${_page + 1} of $count', style: Theme.of(context).textTheme.labelLarge),
            IconButton(
              tooltip: 'Next page',
              icon: const Icon(Icons.chevron_right_rounded),
              onPressed: _page < count - 1
                  ? () => setState(() {
                      _page++;
                      _selectedId = null;
                      _tc.value = Matrix4.identity();
                    })
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.tool, required this.selected, required this.onTap});
  final Tool tool;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: tool.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.m),
        child: Container(
          width: 72,
          decoration: BoxDecoration(
            color: selected ? s.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.m),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(tool.icon, size: 22, color: selected ? s.onSecondaryContainer : s.onSurfaceVariant),
              const SizedBox(height: 4),
              ExcludeSemantics(
                child: Text(
                  tool.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall!
                      .copyWith(color: selected ? s.onSecondaryContainer : s.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.items,
    required this.k,
    required this.selected,
    required this.showHandle,
    required this.liveStroke,
    required this.liveStrokeColor,
    required this.liveStrokeWidth,
    required this.liveRect,
    required this.liveRectRedact,
    required this.primary,
  });

  final List<EditItem> items;
  final double k;
  final EditItem? selected;
  final bool showHandle;
  final List<Offset>? liveStroke;
  final Color liveStrokeColor;
  final double liveStrokeWidth;
  final Rect? liveRect;
  final bool liveRectRedact;
  final Color primary;

  Rect _s(Rect r) => Rect.fromLTRB(r.left * k, r.top * k, r.right * k, r.bottom * k);

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in items) {
      switch (item) {
        case InkItem():
          paintStrokes(
            canvas,
            [
              for (final s in item.strokes) [for (final p in s) p * k],
            ],
            Color(item.color),
            item.width * k,
          );
        case MarkupItem():
          final r = _s(item.rect);
          switch (item.kind) {
            case MarkupKind.highlight:
              canvas.drawRect(
                r,
                Paint()
                  ..color = Color(item.color).withValues(alpha: 0.4)
                  ..blendMode = BlendMode.multiply,
              );
            case MarkupKind.underline:
              final th = (r.height * 0.08).clamp(1.0, 3.0 * k);
              canvas.drawLine(
                Offset(r.left, r.bottom - th),
                Offset(r.right, r.bottom - th),
                Paint()
                  ..color = Color(item.color)
                  ..strokeWidth = th,
              );
            case MarkupKind.strikeout:
              final th = (r.height * 0.08).clamp(1.0, 3.0 * k);
              canvas.drawLine(
                Offset(r.left, r.center.dy),
                Offset(r.right, r.center.dy),
                Paint()
                  ..color = Color(item.color)
                  ..strokeWidth = th,
              );
          }
        case RedactItem():
          final r = _s(item.rect);
          canvas.drawRect(r, Paint()..color = Colors.black.withValues(alpha: 0.75));
          canvas.drawRect(
            r,
            Paint()
              ..color = const Color(0xFFE53935)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
        default:
          break;
      }
    }
    if (liveStroke != null) {
      paintStrokes(
        canvas,
        [
          [for (final p in liveStroke!) p * k],
        ],
        liveStrokeColor,
        liveStrokeWidth * k,
      );
    }
    if (liveRect != null) {
      final r = _s(liveRect!);
      canvas.drawRect(r, Paint()..color = (liveRectRedact ? Colors.black : primary).withValues(alpha: 0.3));
      canvas.drawRect(
        r,
        Paint()
          ..color = liveRectRedact ? const Color(0xFFE53935) : primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final sel = selected;
    if (sel != null) {
      final r = _s(sel.bounds).inflate(3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(4)),
        Paint()
          ..color = primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      if (showHandle) {
        canvas.drawCircle(r.bottomRight, 9, Paint()..color = Colors.white);
        canvas.drawCircle(
          r.bottomRight,
          9,
          Paint()
            ..color = primary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => true;
}

/// Wraps [ResultView] for flows that are not a [ToolScaffold].
class ResultPage extends StatelessWidget {
  const ResultPage({super.key, required this.title, required this.result, required this.saved});
  final String title;
  final ToolResult result;
  final List<LibraryEntry> saved;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: ResultView(result: result, saved: saved, onAgain: () => Navigator.of(context).pop()),
  );
}
