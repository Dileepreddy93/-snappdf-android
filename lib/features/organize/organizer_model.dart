/// One page in the organizer: page [index] of source document [source], or
/// a blank page. [rotate] is the extra clockwise rotation (multiple of 90).
class OrgPage {
  const OrgPage({
    required this.id,
    this.source = 0,
    this.index = 0,
    this.rotate = 0,
    this.blankWidth,
    this.blankHeight,
    this.crop,
  });

  final int id;
  final int source;
  final int index;
  final int rotate;
  final double? blankWidth;
  final double? blankHeight;

  /// Crop margins as fractions (left, top, right, bottom) of the visible page.
  final List<double>? crop;

  bool get isBlank => blankWidth != null;

  OrgPage copyWith({int? id, int? rotate, List<double>? crop, bool clearCrop = false}) => OrgPage(
    id: id ?? this.id,
    source: source,
    index: index,
    rotate: rotate ?? this.rotate,
    blankWidth: blankWidth,
    blankHeight: blankHeight,
    crop: clearCrop ? null : (crop ?? this.crop),
  );

  Map<String, Object?> toArgs() => isBlank
      ? {'blankWidth': blankWidth, 'blankHeight': blankHeight, 'rotate': rotate}
      : {'source': source, 'page': index, 'rotate': rotate, if (crop != null) 'crop': crop};
}

/// Page list with undo/redo. Every mutation pushes a snapshot.
class OrganizerModel {
  OrganizerModel(int pageCount)
    : _pages = [for (var i = 0; i < pageCount; i++) OrgPage(id: i, index: i)],
      _nextId = pageCount,
      _originalCount = pageCount;

  final int _originalCount;

  List<OrgPage> _pages;
  final List<List<OrgPage>> _undo = [];
  final List<List<OrgPage>> _redo = [];
  int _nextId;

  List<OrgPage> get pages => List.unmodifiable(_pages);
  int get length => _pages.length;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// True if the result differs from the untouched original.
  bool get isModified {
    if (_pages.length != _originalCount) return true;
    for (var i = 0; i < _pages.length; i++) {
      final p = _pages[i];
      if (p.source != 0 || p.index != i || p.rotate != 0 || p.isBlank || p.crop != null) return true;
    }
    return false;
  }

  void _commit(List<OrgPage> next) {
    _undo.add(_pages);
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
    _pages = next;
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(_pages);
    _pages = _undo.removeLast();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(_pages);
    _pages = _redo.removeLast();
  }

  void rotate(Set<int> ids, int delta) {
    _commit([
      for (final p in _pages) ids.contains(p.id) ? p.copyWith(rotate: ((p.rotate + delta) % 360 + 360) % 360) : p,
    ]);
  }

  void delete(Set<int> ids) {
    final next = _pages.where((p) => !ids.contains(p.id)).toList();
    if (next.isEmpty) throw StateError('A PDF needs at least one page.');
    _commit(next);
  }

  /// Inserts a copy of each selected page right after it.
  void duplicate(Set<int> ids) {
    final next = <OrgPage>[];
    for (final p in _pages) {
      next.add(p);
      if (ids.contains(p.id)) next.add(p.copyWith(id: _nextId++));
    }
    _commit(next);
  }

  void move(int from, int to) {
    if (from == to || from < 0 || from >= _pages.length) return;
    final next = [..._pages];
    final item = next.removeAt(from);
    next.insert(to.clamp(0, next.length), item);
    _commit(next);
  }

  void insertBlank(int at, double width, double height) {
    final next = [..._pages]
      ..insert(at.clamp(0, _pages.length), OrgPage(id: _nextId++, blankWidth: width, blankHeight: height));
    _commit(next);
  }

  /// Inserts all [count] pages of another source at [at].
  void insertSource(int source, int count, int at) {
    final added = [for (var i = 0; i < count; i++) OrgPage(id: _nextId++, source: source, index: i)];
    final next = [..._pages]..insertAll(at.clamp(0, _pages.length), added);
    _commit(next);
  }

  void setCrop(Set<int> ids, List<double>? crop) {
    _commit([
      for (final p in _pages)
        ids.contains(p.id) && !p.isBlank ? (crop == null ? p.copyWith(clearCrop: true) : p.copyWith(crop: crop)) : p,
    ]);
  }

  List<Map<String, Object?>> toArgs([Set<int>? only]) => [
    for (final p in _pages)
      if (only == null || only.contains(p.id)) p.toArgs(),
  ];
}
