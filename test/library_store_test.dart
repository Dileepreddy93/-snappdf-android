import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:snappdf/core/files/file_kind.dart';
import 'package:snappdf/core/files/library_store.dart';

void main() {
  late Directory root;
  late LibraryStore store;
  var now = DateTime(2026, 1, 1, 10);

  LibraryStore make() => LibraryStore(
    libraryDir: Directory(p.join(root.path, 'library')),
    trashDir: Directory(p.join(root.path, 'trash')),
    indexFile: File(p.join(root.path, 'data', 'library.json')),
    clock: () => now,
  );

  Future<File> temp(String name, String content) async {
    final f = File(p.join(root.path, 'tmp', name));
    await f.parent.create(recursive: true);
    return f.writeAsString(content);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('snappdf_lib');
    now = DateTime(2026, 1, 1, 10);
    store = make();
    await store.load();
  });

  tearDown(() => root.delete(recursive: true));

  test('adds files with private storage names and survives reload', () async {
    final src = await temp('a.pdf', '%PDF-1.7 a');
    final r = await store.add(src, name: 'Report.pdf');
    expect(await src.exists(), isFalse, reason: 'moved by default');
    expect(store.fileOf(r.entry).existsSync(), isTrue);
    expect(r.entry.kind, FileKind.pdf);
    final again = make();
    await again.load();
    expect(again.active.single.name, 'Report.pdf');
    expect(again.active.single.history.single.action, 'Created');
  });

  test('copy mode keeps the source', () async {
    final src = await temp('b.jpg', 'jpg');
    await store.add(src, name: 'b.jpg', move: false);
    expect(await src.exists(), isTrue);
  });

  test('detects duplicate content', () async {
    final a = await store.add(await temp('1.txt', 'same'), name: 'one.txt');
    final b = await store.add(await temp('2.txt', 'same'), name: 'two.txt');
    expect(a.duplicateOf, isNull);
    expect(b.duplicateOf?.id, a.entry.id);
    expect(store.duplicates().single.length, 2);
  });

  test('rename keeps the extension and validates', () async {
    final e = (await store.add(await temp('x.pdf', 'x'), name: 'x.pdf')).entry;
    expect((await store.rename(e.id, 'Invoice March')).name, 'Invoice March.pdf');
    expect((await store.rename(e.id, 'Final.pdf')).name, 'Final.pdf');
    expect((await store.rename(e.id, 'bad/name')).name, 'bad_name.pdf');
    expect(() => store.rename(e.id, '   '), throwsA(isA<LibraryException>()));
  });

  test('duplicate creates an independent copy with a unique name', () async {
    final e = (await store.add(await temp('d.pdf', 'd'), name: 'Doc.pdf')).entry;
    final c1 = await store.duplicate(e.id);
    final c2 = await store.duplicate(e.id);
    expect(c1.name, 'Doc copy.pdf');
    expect(c2.name, 'Doc copy (2).pdf');
    expect(store.fileOf(c1).path, isNot(store.fileOf(e).path));
  });

  test('trash, restore and purge', () async {
    final e = (await store.add(await temp('t.pdf', 't'), name: 't.pdf')).entry;
    await store.trashItems([e.id]);
    expect(store.active, isEmpty);
    expect(store.trash.single.id, e.id);
    expect(store.fileOf(store.byId(e.id)!).existsSync(), isTrue, reason: 'file moved to trash, not deleted');
    await store.restore([e.id]);
    expect(store.active.single.id, e.id);
    expect(store.fileOf(store.byId(e.id)!).existsSync(), isTrue);
    final path = store.fileOf(store.byId(e.id)!).path;
    await store.purge([e.id]);
    expect(store.all, isEmpty);
    expect(File(path).existsSync(), isFalse);
  });

  test('trash older than the retention period is purged on load', () async {
    final e = (await store.add(await temp('o.pdf', 'o'), name: 'o.pdf')).entry;
    await store.trashItems([e.id]);
    now = now.add(const Duration(days: 31));
    final later = make();
    await later.load();
    expect(later.all, isEmpty);
  });

  test('folders, favourites, search and sorting', () async {
    final a = (await store.add(await temp('a', 'aaaa'), name: 'Alpha.pdf')).entry;
    now = now.add(const Duration(minutes: 1));
    final b = (await store.add(await temp('b', 'b'), name: 'beta.jpg')).entry;
    await store.moveToFolder([a.id], 'Work');
    await store.setFavorite(b.id, true);
    expect(store.folders, ['Work']);
    expect(store.query(folder: 'Work').single.id, a.id);
    expect(store.query(favoritesOnly: true).single.id, b.id);
    expect(store.query(text: 'alp').single.id, a.id);
    expect(store.query(kind: FileKind.image).single.id, b.id);
    expect(store.query(sort: LibrarySort.name).map((e) => e.name), ['Alpha.pdf', 'beta.jpg']);
    expect(store.query(sort: LibrarySort.size).first.id, a.id);
    expect(store.query().first.id, b.id, reason: 'most recent first');
    final copies = await store.copyToFolder([b.id], 'Work');
    expect(copies.single.folder, 'Work');
    expect(store.query(folder: 'Work').length, 2);
  });

  test('recovers from a missing file and a corrupt index', () async {
    final e = (await store.add(await temp('m.pdf', 'm'), name: 'm.pdf')).entry;
    await store.fileOf(e).delete();
    final r1 = make();
    await r1.load();
    expect(r1.all, isEmpty, reason: 'entry without a file is dropped');

    final kept = (await r1.add(await temp('k.pdf', 'k'), name: 'k.pdf')).entry;
    await File(p.join(root.path, 'data', 'library.json')).writeAsString('{not json');
    final r2 = make();
    await r2.load();
    expect(r2.active.single.storedName, kept.storedName, reason: 'orphan files are re-adopted');
    expect(File(p.join(root.path, 'data', 'library.json.corrupt')).existsSync(), isTrue);
  });

  test('name helpers', () {
    expect(derivedName('report.pdf', 'compressed'), 'report_compressed.pdf');
    expect(derivedName('photo.jpeg', 'small', extension: 'webp'), 'photo_small.webp');
    expect(uniqueName('a.pdf', ['A.PDF']), 'a (2).pdf');
    expect(uniqueName('a (2).pdf', ['a (2).pdf']), 'a (3).pdf');
    expect(sanitizeFileName('  ..x:y?.pdf'), 'x_y_.pdf');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.00 MB');
  });
}
