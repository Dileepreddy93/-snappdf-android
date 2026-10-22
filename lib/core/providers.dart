import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'files/library_store.dart';
import 'files/workspace.dart';
import 'platform/native_api.dart';
import 'settings.dart';

/// Overridden in main() once directories are known.
final workspaceProvider = Provider<Workspace>((ref) {
  throw UnimplementedError('workspaceProvider must be overridden');
});

final nativeApiProvider = Provider<NativeApi>((ref) => NativeApi());

/// Overridden in main() with a loaded store.
final libraryStoreProvider = Provider<LibraryStore>((ref) {
  throw UnimplementedError('libraryStoreProvider must be overridden');
});

/// Snapshot of the library; bump [revision] after each mutation.
class LibraryState {
  const LibraryState(this.entries, this.revision);
  final List<LibraryEntry> entries;
  final int revision;
}

class LibraryController extends Notifier<LibraryState> {
  LibraryStore get store => ref.read(libraryStoreProvider);

  @override
  LibraryState build() => LibraryState(ref.read(libraryStoreProvider).all, 0);

  void _refresh() => state = LibraryState(store.all, state.revision + 1);

  Future<T> mutate<T>(Future<T> Function(LibraryStore store) action) async {
    try {
      return await action(store);
    } finally {
      _refresh();
    }
  }

  /// Saves a finished output into the library.
  Future<AddResult> addOutput(String path, String name, {String action = 'Created', String? detail}) =>
      mutate((s) => s.add(File(path), name: name, action: action, detail: detail));

  /// Adds an imported original (copied, so the import cache can be cleared).
  Future<AddResult> addImported(String path, String name) =>
      mutate((s) => s.add(File(path), name: name, move: false, action: 'Imported'));
}

final libraryProvider = NotifierProvider<LibraryController, LibraryState>(LibraryController.new);

final settingsStoreProvider = Provider<JsonFileStore>((ref) {
  final ws = ref.watch(workspaceProvider);
  return JsonFileStore(File(p.join(ws.dataDir.path, 'settings.json')));
});

/// Initial settings, loaded in main().
final initialSettingsProvider = Provider<AppSettings>((ref) => const AppSettings());

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(initialSettingsProvider);

  Future<void> update(AppSettings Function(AppSettings s) change) async {
    state = change(state);
    try {
      await ref.read(settingsStoreProvider).write(state.toJson());
    } catch (_) {
      // Settings remain in memory; persistence failures are non-fatal.
    }
  }

  void setThemeMode(ThemeMode mode) => update((s) => s.copyWith(themeMode: mode));
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
