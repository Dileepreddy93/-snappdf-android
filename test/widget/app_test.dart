import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:snappdf/app/app.dart';
import 'package:snappdf/core/files/library_store.dart';
import 'package:snappdf/core/files/workspace.dart';
import 'package:snappdf/core/platform/native_api.dart';
import 'package:snappdf/core/providers.dart';
import 'package:snappdf/core/settings.dart';
import 'package:snappdf/core/tooling/tool_scaffold.dart';
import 'package:snappdf/features/editor/editor_screen.dart';
import 'package:snappdf/features/tools/tool_registry.dart';

/// Native bridge stand-in: records calls, returns neutral results.
class FakeNativeApi extends NativeApi {
  final calls = <String>[];

  @override
  Stream<JobProgress> get progress => const Stream.empty();

  @override
  void attachIncomingHandler() {}

  @override
  Future<T?> call<T>(String method, [Map<String, Object?>? args]) async {
    calls.add(method);
    switch (method) {
      case 'secure.list':
        return <Object>[] as T;
      case 'io.scannerAvailable':
        return false as T;
      case 'io.pickFiles':
        return <Object>[] as T;
      case 'app.takeIncoming':
        return <Object>[] as T;
    }
    return null;
  }
}

class Harness {
  Harness(this.root, this.store, this.api, this.ws);
  final Directory root;
  final LibraryStore store;
  final FakeNativeApi api;
  final Workspace ws;

  static Future<Harness> create() async {
    final root = Directory.systemTemp.createTempSync('snappdf_widget');
    final ws = Workspace(root: Directory(p.join(root.path, 'docs')), cache: Directory(p.join(root.path, 'cache')));
    await ws.ensure();
    final store = LibraryStore(
      libraryDir: ws.libraryDir,
      trashDir: ws.trashDir,
      indexFile: File(p.join(ws.dataDir.path, 'library.json')),
    );
    await store.load();
    return Harness(root, store, FakeNativeApi(), ws);
  }

  Widget app({AppSettings settings = const AppSettings()}) => ProviderScope(
    overrides: [
      workspaceProvider.overrideWithValue(ws),
      libraryStoreProvider.overrideWithValue(store),
      nativeApiProvider.overrideWithValue(api),
      initialSettingsProvider.overrideWithValue(settings),
    ],
    child: const SnapApp(handleIncoming: false),
  );

  Future<LibraryEntry> seed(String name, String content) async {
    final f = File(p.join(root.path, 'seed', name));
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return (await store.add(f, name: name)).entry;
  }
}

Future<void> pumpApp(
  WidgetTester tester,
  Harness h, {
  AppSettings settings = const AppSettings(),
  Size size = const Size(412, 915),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(h.app(settings: settings));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

/// Taps inside the real event loop, so file I/O started by the tap handler
/// (library store) can complete, then settles the UI.
Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pumpAndSettle();
}

Future<void> tapChip(WidgetTester tester, String label) async {
  final chip = find.widgetWithText(ChoiceChip, label);
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
}

/// Lets real file I/O (library store) complete, then settles the UI.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pumpAndSettle();
  }
}

void main() {
  late Harness h;
  setUp(() async => h = await Harness.create());
  tearDown(() => h.root.deleteSync(recursive: true));

  testWidgets('all four navigation destinations work', (tester) async {
    await pumpApp(tester, h);
    expect(find.text('Quick actions'), findsOneWidget);
    for (final (label, marker) in [
      ('Tools', 'Organize PDF'),
      ('Files', 'No files yet'),
      ('Settings', 'Appearance'),
      ('Home', 'Quick actions'),
    ]) {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
      await tester.pumpAndSettle();
      expect(find.text(marker), findsWidgets, reason: label);
    }
  });

  for (final dark in [false, true]) {
    testWidgets('every tool opens and shows its title (${dark ? 'dark' : 'light'})', (tester) async {
      await pumpApp(tester, h, settings: AppSettings(themeMode: dark ? ThemeMode.dark : ThemeMode.light));
      final router = GoRouterHelper.of(tester);
      for (final tool in allTools) {
        unawaited(router.push('/tool/${tool.id}'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tool.id);
        expect(find.byType(AppBar), findsWidgets, reason: tool.id);
        router.pop();
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets('tools fit a small 320 dp screen without overflow', (tester) async {
    await pumpApp(tester, h, size: const Size(320, 640));
    final router = GoRouterHelper.of(tester);
    for (final route in ['/home', '/tools', '/files', '/settings']) {
      router.go(route);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: route);
    }
    for (final tool in allTools) {
      unawaited(router.push('/tool/${tool.id}'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tool.id);
      router.pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('quick action opens a tool; back returns home', (tester) async {
    await pumpApp(tester, h);
    await tester.tap(find.text('Merge PDFs').first);
    await tester.pumpAndSettle();
    expect(find.text('Add PDFs to merge'), findsOneWidget);
    expect(find.text('Add at least two PDFs'), findsOneWidget, reason: 'disabled reason is visible');
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Merge'), matching: find.byWidgetPredicate((w) => w is FilledButton)),
    );
    expect(button.onPressed, isNull, reason: 'action disabled until inputs are added');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Quick actions'), findsOneWidget);
  });

  testWidgets('search finds tools by task', (tester) async {
    await pumpApp(tester, h);
    await tester.tap(find.text('Search tools and files'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.pumpAndSettle();
    expect(find.text('Protect PDF'), findsOneWidget);
    expect(find.text('Remove password'), findsOneWidget);
    expect(find.text('Merge PDFs'), findsNothing);
    await tester.tap(find.text('Protect PDF'));
    await tester.pumpAndSettle();
    expect(find.text('Password to open'), findsOneWidget);
  });

  testWidgets('choosing a source and cancelling the picker keeps the tool usable', (tester) async {
    await pumpApp(tester, h);
    unawaited(GoRouterHelper.of(tester).push('/tool/compress_pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add PDF files'));
    await tester.pumpAndSettle();
    expect(find.text('Browse device'), findsOneWidget);
    await tester.tap(find.text('Browse device'));
    await tester.pumpAndSettle();
    expect(h.api.calls, contains('io.pickFiles'));
    expect(find.text('Compress PDF'), findsWidgets);
  });

  testWidgets('files: list, favourite, trash and restore', (tester) async {
    await tester.runAsync(() async {
      await h.seed('Invoice.pdf', '%PDF-1.4 fake');
      await h.seed('Photo.jpg', 'jpg');
    });
    await pumpApp(tester, h, size: const Size(800, 1000));
    GoRouterHelper.of(tester).go('/files');
    await tester.pumpAndSettle();
    expect(find.text('Invoice.pdf'), findsOneWidget);
    expect(find.text('Photo.jpg'), findsOneWidget);

    await tapAndWait(tester, find.byTooltip('More options for Invoice.pdf'));
    await tapAndWait(tester, find.text('Add to favourites'));
    await tapChip(tester, 'Favourites');
    await tester.pumpAndSettle();
    expect(find.text('Invoice.pdf'), findsOneWidget);
    expect(find.text('Photo.jpg'), findsNothing);

    await tapChip(tester, 'All');
    await tester.pumpAndSettle();
    await tapAndWait(tester, find.byTooltip('More options for Photo.jpg'));
    await tapAndWait(tester, find.text('Move to trash'));
    expect(find.text('Photo.jpg'), findsNothing);
    expect(h.store.trash.single.name, 'Photo.jpg');

    await tapChip(tester, 'Trash');
    await tester.pumpAndSettle();
    await tapAndWait(tester, find.text('Photo.jpg'));
    await tapAndWait(tester, find.text('Restore'));
    expect(h.store.trash, isEmpty);
    expect(find.text('Trash is empty'), findsOneWidget);
  });

  testWidgets('files: rename through the dialog', (tester) async {
    await tester.runAsync(() => h.seed('draft.pdf', '%PDF'));
    await pumpApp(tester, h, size: const Size(800, 1000));
    GoRouterHelper.of(tester).go('/files');
    await tester.pumpAndSettle();
    await tapAndWait(tester, find.byTooltip('More options for draft.pdf'));
    await tapAndWait(tester, find.text('Rename'));
    await tester.enterText(find.byType(TextField).last, 'Final contract');
    await tapAndWait(tester, find.text('OK'));
    expect(find.text('Final contract.pdf'), findsOneWidget);
  });

  testWidgets('result screen opens the saved file through the router', (tester) async {
    late LibraryEntry entry;
    await tester.runAsync(() async => entry = await h.seed('Notes.txt', 'hello from the result page'));
    await pumpApp(tester, h);
    final router = GoRouterHelper.of(tester);
    unawaited(router.push('/tool/edit_pdf'));
    await tester.pumpAndSettle();
    // Same pattern as the editor after saving: replace the tool with its result.
    unawaited(
      router.pushReplacement(
        '/result',
        extra: ResultPage(
          title: 'Edit PDF',
          result: const ToolResult(headline: 'Changes saved'),
          saved: [entry],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Changes saved'), findsOneWidget);
    await tester.tap(find.text('Open'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(AppBar, 'Notes.txt'), findsOneWidget, reason: 'viewer opened');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Changes saved'), findsOneWidget);
  });

  testWidgets('settings switch theme', (tester) async {
    await pumpApp(tester, h, settings: const AppSettings(themeMode: ThemeMode.light));
    GoRouterHelper.of(tester).go('/settings');
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('Appearance'))).brightness, Brightness.light);
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('Appearance'))).brightness, Brightness.dark);
    expect(find.text('Your documents stay on this device'), findsOneWidget);
  });

  testWidgets('interactive controls have accessible labels', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, h);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  });
}

/// Access the app's GoRouter from tests.
class GoRouterHelper {
  static GoRouter of(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Navigator).first));
}
