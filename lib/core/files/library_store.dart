import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'file_kind.dart';

class HistoryEvent {
  const HistoryEvent(this.at, this.action, [this.detail]);
  final DateTime at;
  final String action;
  final String? detail;

  Map<String, Object?> toJson() => {'at': at.millisecondsSinceEpoch, 'action': action, 'detail': detail};

  factory HistoryEvent.fromJson(Map<String, Object?> j) =>
      HistoryEvent(DateTime.fromMillisecondsSinceEpoch(j['at'] as int), j['action'] as String, j['detail'] as String?);
}

/// A document kept in the app's private library.
class LibraryEntry {
  LibraryEntry({
    required this.id,
    required this.name,
    required this.storedName,
    required this.size,
    required this.sha256,
    required this.createdAt,
    required this.modifiedAt,
    this.openedAt,
    this.favorite = false,
    this.folder = '',
    this.deletedAt,
    this.history = const [],
  });

  final String id;

  /// Display name including extension.
  final String name;

  /// File name on disk (id-based, never shown).
  final String storedName;
  final int size;
  final String sha256;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final DateTime? openedAt;
  final bool favorite;

  /// Virtual folder ('' = top level).
  final String folder;

  /// Set while the file is in the trash.
  final DateTime? deletedAt;
  final List<HistoryEvent> history;

  FileKind get kind => FileKind.ofName(name);
  String get mime => mimeForName(name);
  bool get inTrash => deletedAt != null;
  DateTime get lastUsed => openedAt != null && openedAt!.isAfter(modifiedAt) ? openedAt! : modifiedAt;

  LibraryEntry copyWith({
    String? name,
    String? storedName,
    int? size,
    String? sha256,
    DateTime? modifiedAt,
    DateTime? openedAt,
    bool? favorite,
    String? folder,
    DateTime? deletedAt,
    bool clearDeleted = false,
    List<HistoryEvent>? history,
  }) => LibraryEntry(
    id: id,
    name: name ?? this.name,
    storedName: storedName ?? this.storedName,
    size: size ?? this.size,
    sha256: sha256 ?? this.sha256,
    createdAt: createdAt,
    modifiedAt: modifiedAt ?? this.modifiedAt,
    openedAt: openedAt ?? this.openedAt,
    favorite: favorite ?? this.favorite,
    folder: folder ?? this.folder,
    deletedAt: clearDeleted ? null : (deletedAt ?? this.deletedAt),
    history: history ?? this.history,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'storedName': storedName,
    'size': size,
    'sha256': sha256,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'modifiedAt': modifiedAt.millisecondsSinceEpoch,
    'openedAt': openedAt?.millisecondsSinceEpoch,
    'favorite': favorite,
    'folder': folder,
    'deletedAt': deletedAt?.millisecondsSinceEpoch,
    'history': [for (final h in history) h.toJson()],
  };

  factory LibraryEntry.fromJson(Map<String, Object?> j) {
    DateTime? d(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    return LibraryEntry(
      id: j['id'] as String,
      name: j['name'] as String,
      storedName: j['storedName'] as String,
      size: j['size'] as int,
      sha256: j['sha256'] as String,
      createdAt: d(j['createdAt'])!,
      modifiedAt: d(j['modifiedAt'])!,
      openedAt: d(j['openedAt']),
      favorite: j['favorite'] as bool? ?? false,
      folder: j['folder'] as String? ?? '',
      deletedAt: d(j['deletedAt']),
      history: [
        for (final h in (j['history'] as List? ?? const [])) HistoryEvent.fromJson((h as Map).cast<String, Object?>()),
      ],
    );
  }
}

class LibraryException implements Exception {
  LibraryException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum LibrarySort { recent, name, size, type }

/// Result of adding a file: the new entry and, if the same content already
/// exists in the library, that earlier entry.
class AddResult {
  const AddResult(this.entry, this.duplicateOf);
  final LibraryEntry entry;
  final LibraryEntry? duplicateOf;
}

/// Persistent index of library files. All writes are atomic (temp + rename),
/// and the index is reconciled with the files on disk when loaded.
class LibraryStore {
  LibraryStore({required this.libraryDir, required this.trashDir, required this.indexFile, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Directory libraryDir;
  final Directory trashDir;
  final File indexFile;
  final DateTime Function() _clock;
  static const _uuid = Uuid();

  /// Trash items older than this are purged on load.
  static const trashRetention = Duration(days: 30);

  final Map<String, LibraryEntry> _entries = {};

  List<LibraryEntry> get all => List.unmodifiable(_entries.values);
  List<LibraryEntry> get active => _entries.values.where((e) => !e.inTrash).toList();
  List<LibraryEntry> get trash => _entries.values.where((e) => e.inTrash).toList();
  LibraryEntry? byId(String id) => _entries[id];

  File fileOf(LibraryEntry e) => File(p.join((e.inTrash ? trashDir : libraryDir).path, e.storedName));

  Future<void> load() async {
    await libraryDir.create(recursive: true);
    await trashDir.create(recursive: true);
    _entries.clear();
    if (await indexFile.exists()) {
      try {
        final data = jsonDecode(await indexFile.readAsString()) as Map;
        for (final j in (data['entries'] as List? ?? const [])) {
          final e = LibraryEntry.fromJson((j as Map).cast<String, Object?>());
          _entries[e.id] = e;
        }
      } on FormatException {
        // A damaged index is preserved for diagnosis; files are re-adopted below.
        await indexFile.rename('${indexFile.path}.corrupt');
      }
    }
    var changed = false;
    // Drop entries whose files have disappeared.
    for (final e in _entries.values.toList()) {
      if (!await fileOf(e).exists()) {
        _entries.remove(e.id);
        changed = true;
      }
    }
    // Re-adopt files present on disk but missing from the index.
    final known = _entries.values.map((e) => e.storedName).toSet();
    await for (final f in libraryDir.list()) {
      if (f is! File) continue;
      final name = p.basename(f.path);
      if (name.startsWith('.') || known.contains(name)) continue;
      final now = _clock();
      final id = p.basenameWithoutExtension(name);
      _entries[id] = LibraryEntry(
        id: id,
        name: 'Recovered${p.extension(name)}',
        storedName: name,
        size: await f.length(),
        sha256: await _hash(f),
        createdAt: now,
        modifiedAt: now,
        history: [HistoryEvent(now, 'Recovered')],
      );
      changed = true;
    }
    // Purge expired trash.
    final cutoff = _clock().subtract(trashRetention);
    for (final e in trash) {
      if (e.deletedAt!.isBefore(cutoff)) {
        await _deleteFile(fileOf(e));
        _entries.remove(e.id);
        changed = true;
      }
    }
    if (changed) await _save();
  }

  Future<void> _save() async {
    await indexFile.parent.create(recursive: true);
    final tmp = File('${indexFile.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'version': 1,
        'entries': [for (final e in _entries.values) e.toJson()],
      }),
      flush: true,
    );
    await tmp.rename(indexFile.path);
  }

  static Future<String> _hash(File f) async => (await sha256.bind(f.openRead()).first).toString();

  /// Adds [source] to the library under display name [name]. With [move]
  /// the source file is moved instead of copied (for temporary outputs).
  Future<AddResult> add(
    File source, {
    required String name,
    bool move = true,
    String action = 'Created',
    String? detail,
    String folder = '',
  }) async {
    if (!await source.exists()) {
      throw LibraryException('The file to save no longer exists.');
    }
    final id = _uuid.v4();
    var ext = p.extension(name).toLowerCase();
    if (ext.isEmpty) ext = p.extension(source.path).toLowerCase();
    final displayName = sanitizeFileName(p.extension(name).isEmpty ? '$name$ext' : name);
    final storedName = '$id$ext';
    final target = File(p.join(libraryDir.path, storedName));
    await libraryDir.create(recursive: true);
    if (move) {
      try {
        await source.rename(target.path);
      } on FileSystemException {
        // Different filesystem (cache vs files): copy then delete.
        await source.copy(target.path);
        await _deleteFile(source);
      }
    } else {
      await source.copy(target.path);
    }
    final hash = await _hash(target);
    final now = _clock();
    final duplicate = active.where((e) => e.sha256 == hash).fold<LibraryEntry?>(null, (a, b) => a ?? b);
    final entry = LibraryEntry(
      id: id,
      name: displayName,
      storedName: storedName,
      size: await target.length(),
      sha256: hash,
      createdAt: now,
      modifiedAt: now,
      folder: folder,
      history: [HistoryEvent(now, action, detail)],
    );
    _entries[id] = entry;
    await _save();
    return AddResult(entry, duplicate);
  }

  LibraryEntry _require(String id) {
    final e = _entries[id];
    if (e == null) throw LibraryException('This file is no longer in your library.');
    return e;
  }

  Future<LibraryEntry> _update(LibraryEntry e) async {
    _entries[e.id] = e;
    await _save();
    return e;
  }

  /// Renames the display name; the extension is preserved.
  Future<LibraryEntry> rename(String id, String newName) async {
    final e = _require(id);
    final ext = p.extension(e.name);
    var stem = newName.trim();
    if (stem.toLowerCase().endsWith(ext.toLowerCase())) {
      stem = stem.substring(0, stem.length - ext.length);
    }
    stem = sanitizeFileName(stem, fallback: '');
    if (stem.isEmpty) throw LibraryException('Enter a file name.');
    return _update(
      e.copyWith(
        name: '$stem$ext',
        modifiedAt: _clock(),
        history: [...e.history, HistoryEvent(_clock(), 'Renamed', e.name)],
      ),
    );
  }

  Future<LibraryEntry> duplicate(String id) async {
    final e = _require(id);
    final names = active.where((x) => x.folder == e.folder).map((x) => x.name);
    final copyName = uniqueName('${p.basenameWithoutExtension(e.name)} copy${p.extension(e.name)}', names);
    final result = await add(
      fileOf(e),
      name: copyName,
      move: false,
      action: 'Duplicated',
      detail: e.name,
      folder: e.folder,
    );
    return result.entry;
  }

  Future<void> setFavorite(String id, bool favorite) async {
    await _update(_require(id).copyWith(favorite: favorite));
  }

  Future<void> markOpened(String id) async {
    final e = _entries[id];
    if (e != null) await _update(e.copyWith(openedAt: _clock()));
  }

  Future<void> moveToFolder(Iterable<String> ids, String folder) async {
    final clean = folder.trim();
    for (final id in ids) {
      final e = _require(id);
      _entries[id] = e.copyWith(
        folder: clean,
        history: [...e.history, HistoryEvent(_clock(), 'Moved', clean.isEmpty ? 'Top level' : clean)],
      );
    }
    await _save();
  }

  Future<List<LibraryEntry>> copyToFolder(Iterable<String> ids, String folder) async {
    final out = <LibraryEntry>[];
    for (final id in ids) {
      final e = _require(id);
      final names = active.where((x) => x.folder == folder).map((x) => x.name);
      final r = await add(
        fileOf(e),
        name: uniqueName(e.name, names),
        move: false,
        action: 'Copied',
        detail: e.name,
        folder: folder.trim(),
      );
      out.add(r.entry);
    }
    return out;
  }

  /// Moves to trash; recoverable for [trashRetention].
  Future<void> trashItems(Iterable<String> ids) async {
    await trashDir.create(recursive: true);
    for (final id in ids) {
      final e = _require(id);
      if (e.inTrash) continue;
      final from = fileOf(e);
      final trashed = e.copyWith(deletedAt: _clock());
      await _moveFile(from, fileOf(trashed));
      _entries[id] = trashed;
    }
    await _save();
  }

  Future<void> restore(Iterable<String> ids) async {
    for (final id in ids) {
      final e = _require(id);
      if (!e.inTrash) continue;
      final restored = e.copyWith(clearDeleted: true);
      await _moveFile(fileOf(e), fileOf(restored));
      _entries[id] = restored.copyWith(history: [...e.history, HistoryEvent(_clock(), 'Restored')]);
    }
    await _save();
  }

  /// Permanently deletes (from trash or library).
  Future<void> purge(Iterable<String> ids) async {
    for (final id in ids) {
      final e = _entries.remove(id);
      if (e != null) await _deleteFile(fileOf(e));
    }
    await _save();
  }

  Future<void> emptyTrash() => purge(trash.map((e) => e.id).toList());

  Future<LibraryEntry> recordHistory(String id, String action, [String? detail]) async {
    final e = _require(id);
    return _update(e.copyWith(history: [...e.history, HistoryEvent(_clock(), action, detail)]));
  }

  List<String> get folders {
    final set = active.map((e) => e.folder).where((f) => f.isNotEmpty).toSet().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return set;
  }

  /// Groups of active entries with identical content.
  List<List<LibraryEntry>> duplicates() {
    final groups = <String, List<LibraryEntry>>{};
    for (final e in active) {
      groups.putIfAbsent(e.sha256, () => []).add(e);
    }
    return groups.values.where((g) => g.length > 1).toList();
  }

  List<LibraryEntry> query({
    String text = '',
    FileKind? kind,
    bool favoritesOnly = false,
    String? folder,
    LibrarySort sort = LibrarySort.recent,
    bool trashOnly = false,
  }) {
    final q = text.trim().toLowerCase();
    final list = (trashOnly ? trash : active).where((e) {
      if (kind != null && e.kind != kind) return false;
      if (favoritesOnly && !e.favorite) return false;
      if (folder != null && e.folder != folder) return false;
      if (q.isNotEmpty && !e.name.toLowerCase().contains(q) && !e.folder.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
    switch (sort) {
      case LibrarySort.recent:
        list.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
      case LibrarySort.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case LibrarySort.size:
        list.sort((a, b) => b.size.compareTo(a.size));
      case LibrarySort.type:
        list.sort((a, b) {
          final k = a.kind.index.compareTo(b.kind.index);
          return k != 0 ? k : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    }
    return list;
  }

  Future<void> _moveFile(File from, File to) async {
    await to.parent.create(recursive: true);
    try {
      await from.rename(to.path);
    } on FileSystemException {
      await from.copy(to.path);
      await _deleteFile(from);
    }
  }

  static Future<void> _deleteFile(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // Best effort.
    }
  }
}
