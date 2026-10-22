import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/design/widgets.dart';
import '../core/providers.dart';
import '../core/tooling/tool_scaffold.dart';
import 'router.dart';
import 'theme.dart';

class SnapApp extends ConsumerStatefulWidget {
  const SnapApp({super.key, this.router, this.handleIncoming = true});
  final GoRouter? router;
  final bool handleIncoming;

  @override
  ConsumerState<SnapApp> createState() => _SnapAppState();
}

class _SnapAppState extends ConsumerState<SnapApp> {
  late final GoRouter _router = widget.router ?? buildRouter();

  @override
  void initState() {
    super.initState();
    if (widget.handleIncoming) {
      final api = ref.read(nativeApiProvider);
      api.onIncomingAvailable = _takeIncoming;
      api.attachIncomingHandler();
      WidgetsBinding.instance.addPostFrameCallback((_) => _takeIncoming());
    }
    unawaited(ref.read(workspaceProvider).cleanWork());
  }

  /// Files shared to SnapPDF or opened with it from other apps.
  Future<void> _takeIncoming() async {
    try {
      final files = await ref.read(nativeApiProvider).takeIncoming();
      if (files.isEmpty) return;
      final lib = ref.read(libraryProvider.notifier);
      final entries = [for (final f in files) (await lib.addImported(f.path, f.name)).entry];
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      if (entries.length == 1) {
        openEntry(ctx, entries.first);
      } else {
        _router.go('/files');
        showMessage(ctx, 'Added ${entries.length} files');
      }
    } catch (_) {
      // Nothing to import or the bridge is unavailable (tests).
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(settingsProvider.select((s) => s.themeMode));
    return MaterialApp.router(
      title: 'SnapPDF',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      routerConfig: _router,
    );
  }
}
