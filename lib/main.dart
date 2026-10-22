import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app/app.dart';
import 'core/files/library_store.dart';
import 'core/files/workspace.dart';
import 'core/providers.dart';
import 'core/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();

  final docs = await getApplicationDocumentsDirectory();
  final cache = await getTemporaryDirectory();
  final ws = Workspace(root: docs, cache: cache);
  await ws.ensure();

  final store = LibraryStore(
    libraryDir: ws.libraryDir,
    trashDir: ws.trashDir,
    indexFile: File(p.join(ws.dataDir.path, 'library.json')),
  );
  await store.load();

  final settingsJson = await JsonFileStore(File(p.join(ws.dataDir.path, 'settings.json'))).read();
  final settings = settingsJson == null ? const AppSettings() : AppSettings.fromJson(settingsJson);

  runApp(
    ProviderScope(
      overrides: [
        workspaceProvider.overrideWithValue(ws),
        libraryStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(settings),
      ],
      child: const SnapApp(),
    ),
  );
}
