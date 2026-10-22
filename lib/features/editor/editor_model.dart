import 'dart:ui';

/// Items placed in the editor. All geometry is in PDF display-space points
/// of the item's page (origin top-left, y down, page rotation applied),
/// which is exactly what the native engine expects.
sealed class EditItem {
  const EditItem(this.id, this.page);
  final int id;
  final int page;

  Rect get bounds;
  EditItem translated(Offset delta);

  /// Native edit description, or null for items handled separately.
  Map<String, Object?>? toEdit();
}

const double kTextLineHeight = 1.25;

class TextItem extends EditItem {
  const TextItem(
    super.id,
    super.page, {
    required this.origin,
    required this.text,
    required this.fontSize,
    required this.color,
    this.bold = false,
    required this.size,
    required this.baseline,
  });

  final Offset origin;
  final String text;
  final double fontSize;
  final int color;
  final bool bold;

  /// Measured text block size in points.
  final Size size;

  /// Distance from the top to the first baseline, in points.
  final double baseline;

  @override
  Rect get bounds => origin & size;

  @override
  TextItem translated(Offset d) => copyWith(origin: origin + d);

  TextItem copyWith({
    Offset? origin,
    String? text,
    double? fontSize,
    int? color,
    bool? bold,
    Size? size,
    double? baseline,
  }) => TextItem(
    id,
    page,
    origin: origin ?? this.origin,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
    color: color ?? this.color,
    bold: bold ?? this.bold,
    size: size ?? this.size,
    baseline: baseline ?? this.baseline,
  );

  @override
  Map<String, Object?> toEdit() => {
    'type': 'text',
    'page': page,
    'x': origin.dx,
    'y': origin.dy,
    'text': text,
    'fontSize': fontSize,
    'color': color,
    'bold': bold,
    'baseline': baseline,
    'lineHeight': fontSize * kTextLineHeight,
  };
}

class ImageItem extends EditItem {
  const ImageItem(
    super.id,
    super.page, {
    required this.rect,
    required this.path,
    this.rotation = 0,
    this.isSignature = false,
  });
  final Rect rect;
  final String path;

  /// Clockwise degrees.
  final double rotation;
  final bool isSignature;

  double get aspect => rect.width / rect.height;

  @override
  Rect get bounds => rect;

  @override
  ImageItem translated(Offset d) => copyWith(rect: rect.shift(d));

  ImageItem copyWith({Rect? rect, double? rotation}) => ImageItem(
    id,
    page,
    rect: rect ?? this.rect,
    path: path,
    rotation: rotation ?? this.rotation,
    isSignature: isSignature,
  );

  @override
  Map<String, Object?> toEdit() => {
    'type': 'image',
    'page': page,
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    'path': path,
    'rotation': rotation,
  };
}

class InkItem extends EditItem {
  const InkItem(super.id, super.page, {required this.strokes, required this.color, required this.width});
  final List<List<Offset>> strokes;
  final int color;
  final double width;

  @override
  Rect get bounds {
    Rect? r;
    for (final s in strokes) {
      for (final p in s) {
        final pr = Rect.fromCircle(center: p, radius: width / 2 + 2);
        r = r == null ? pr : r.expandToInclude(pr);
      }
    }
    return r ?? Rect.zero;
  }

  @override
  InkItem translated(Offset d) => InkItem(
    id,
    page,
    strokes: [
      for (final s in strokes) [for (final p in s) p + d],
    ],
    color: color,
    width: width,
  );

  @override
  Map<String, Object?> toEdit() => {
    'type': 'ink',
    'page': page,
    'strokes': [
      for (final s in strokes)
        [
          for (final p in s) ...[p.dx, p.dy],
        ],
    ],
    'color': color,
    'width': width,
  };
}

enum MarkupKind { highlight, underline, strikeout }

class MarkupItem extends EditItem {
  const MarkupItem(super.id, super.page, {required this.kind, required this.rect, required this.color});
  final MarkupKind kind;
  final Rect rect;
  final int color;

  @override
  Rect get bounds => rect;

  @override
  MarkupItem translated(Offset d) => MarkupItem(id, page, kind: kind, rect: rect.shift(d), color: color);

  @override
  Map<String, Object?> toEdit() => {
    'type': kind.name,
    'page': page,
    'rect': [rect.left, rect.top, rect.right, rect.bottom],
    'color': color,
  };
}

class NoteItem extends EditItem {
  const NoteItem(super.id, super.page, {required this.at, required this.text, this.color = 0xFFF9A825});
  final Offset at;
  final String text;
  final int color;
  static const double iconSize = 22;

  @override
  Rect get bounds => at & const Size(iconSize, iconSize);

  @override
  NoteItem translated(Offset d) => NoteItem(id, page, at: at + d, text: text, color: color);

  NoteItem withText(String t) => NoteItem(id, page, at: at, text: t, color: color);

  @override
  Map<String, Object?> toEdit() => {'type': 'note', 'page': page, 'x': at.dx, 'y': at.dy, 'text': text, 'color': color};
}

class StampItem extends EditItem {
  const StampItem(super.id, super.page, {required this.rect, required this.text, required this.color});
  final Rect rect;
  final String text;
  final int color;

  @override
  Rect get bounds => rect;

  @override
  StampItem translated(Offset d) => copyWith(rect: rect.shift(d));

  StampItem copyWith({Rect? rect}) => StampItem(id, page, rect: rect ?? this.rect, text: text, color: color);

  @override
  Map<String, Object?> toEdit() => {
    'type': 'stamp',
    'page': page,
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    'text': text,
    'color': color,
  };
}

class RedactItem extends EditItem {
  const RedactItem(super.id, super.page, {required this.rect});
  final Rect rect;

  @override
  Rect get bounds => rect;

  @override
  RedactItem translated(Offset d) => RedactItem(id, page, rect: rect.shift(d));

  RedactItem copyWith({Rect? rect}) => RedactItem(id, page, rect: rect ?? this.rect);

  @override
  Map<String, Object?>? toEdit() => null;
}

/// Ordered item list with undo/redo.
class EditorModel {
  List<EditItem> _items = const [];
  final List<List<EditItem>> _undo = [];
  final List<List<EditItem>> _redo = [];
  int _nextId = 1;

  List<EditItem> get items => _items;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get isEmpty => _items.isEmpty;
  int newId() => _nextId++;

  List<EditItem> onPage(int page) => _items.where((i) => i.page == page).toList();
  EditItem? byId(int id) => _items.where((i) => i.id == id).firstOrNull;

  void _commit(List<EditItem> next) {
    _undo.add(_items);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    _items = List.unmodifiable(next);
  }

  void add(EditItem item) => _commit([..._items, item]);

  void replace(EditItem item) => _commit([for (final i in _items) i.id == item.id ? item : i]);

  void remove(int id) => _commit(_items.where((i) => i.id != id).toList());

  void undo() {
    if (!canUndo) return;
    _redo.add(_items);
    _items = _undo.removeLast();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(_items);
    _items = _redo.removeLast();
  }

  /// Topmost item on [page] containing [p], with [slop] points tolerance.
  EditItem? hitTest(int page, Offset p, {double slop = 6}) {
    for (final item in _items.reversed) {
      if (item.page != page) continue;
      if (item.bounds.inflate(slop).contains(p)) return item;
    }
    return null;
  }

  List<Map<String, Object?>> toEdits() => [
    for (final i in _items)
      if (i.toEdit() != null) i.toEdit()!,
  ];

  /// Redaction rectangles per page as [left, top, right, bottom].
  Map<int, List<List<double>>> redactions() {
    final out = <int, List<List<double>>>{};
    for (final i in _items.whereType<RedactItem>()) {
      out.putIfAbsent(i.page, () => []).add([i.rect.left, i.rect.top, i.rect.right, i.rect.bottom]);
    }
    return out;
  }
}

/// Normalises a drag rectangle and clamps it to the page.
Rect dragRect(Offset a, Offset b, Size page) {
  final r = Rect.fromPoints(a, b);
  return Rect.fromLTRB(
    r.left.clamp(0, page.width),
    r.top.clamp(0, page.height),
    r.right.clamp(0, page.width),
    r.bottom.clamp(0, page.height),
  );
}

/// Resizes [r] by dragging its bottom-right corner, keeping [aspect] if given.
Rect resizeFromCorner(Rect r, Offset delta, {double? aspect, double minSize = 8}) {
  var w = (r.width + delta.dx).clamp(minSize, double.infinity).toDouble();
  var h = (r.height + delta.dy).clamp(minSize, double.infinity).toDouble();
  if (aspect != null) {
    if (delta.dx.abs() >= delta.dy.abs()) {
      h = w / aspect;
    } else {
      w = h * aspect;
    }
  }
  return Rect.fromLTWH(r.left, r.top, w, h);
}
