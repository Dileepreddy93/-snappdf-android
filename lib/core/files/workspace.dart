import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// App-private directory layout. Nothing here is visible to other apps;
/// files leave the sandbox only through explicit Save, Share or Print.
class Workspace {
  Workspace({required this.root, required this.cache});

  /// Persistent app documents directory.
  final Directory root;

  /// Cache directory; the OS may clear it.
  final Directory cache;

  static const _uuid = Uuid();

  Directory get libraryDir => Directory(p.join(root.path, 'library'));
  Directory get trashDir => Directory(p.join(root.path, 'trash'));
  Directory get dataDir => Directory(p.join(root.path, 'data'));
  Directory get workDir => Directory(p.join(cache.path, 'work'));

  Future<void> ensure() async {
    for (final d in [libraryDir, trashDir, dataDir, workDir]) {
      await d.create(recursive: true);
    }
  }

  /// A fresh private directory for one operation's intermediate files.
  Future<Directory> newWorkDir() async {
    final d = Directory(p.join(workDir.path, _uuid.v4()));
    await d.create(recursive: true);
    return d;
  }

  /// Path for a new temporary output named [name] (not yet created).
  Future<String> newWorkFile(String name) async => p.join((await newWorkDir()).path, name);

  /// Deletes temporary work older than [maxAge].
  Future<void> cleanWork({Duration maxAge = const Duration(hours: 12)}) async {
    if (!await workDir.exists()) return;
    final now = DateTime.now();
    await for (final e in workDir.list()) {
      try {
        final stat = await e.stat();
        if (now.difference(stat.modified) > maxAge) {
          await e.delete(recursive: true);
        }
      } on FileSystemException {
        // In use or already gone.
      }
    }
  }

  Future<int> directorySize(Directory d) async {
    if (!await d.exists()) return 0;
    var total = 0;
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } on FileSystemException {
          // ignore
        }
      }
    }
    return total;
  }
}
