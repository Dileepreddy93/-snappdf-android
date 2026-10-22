import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:snappdf/app/app.dart';
import 'package:snappdf/core/files/library_store.dart';
import 'package:snappdf/core/files/workspace.dart';
import 'package:snappdf/core/platform/native_api.dart';
import 'package:snappdf/core/providers.dart';
import 'package:snappdf/features/image/engine/image_engine.dart';
import 'package:snappdf/features/image/engine/image_format.dart';

/// End-to-end flows on a real Android device/emulator. File pickers are
/// system UI and cannot be automated, so inputs are generated on the device;
/// every other step uses the production engines, and every output is
/// reopened with an independent engine (PDFium via pdfrx) for verification.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final api = NativeApi();
  late Workspace ws;
  late LibraryStore store;
  late Directory dir;

  setUpAll(() async {
    await pdfrxFlutterInitialize();
    final docs = await getApplicationDocumentsDirectory();
    final cache = await getTemporaryDirectory();
    ws = Workspace(root: Directory(p.join(docs.path, 'itest')), cache: Directory(p.join(cache.path, 'itest')));
    await ws.ensure();
    store = LibraryStore(
      libraryDir: ws.libraryDir,
      trashDir: ws.trashDir,
      indexFile: File(p.join(ws.dataDir.path, 'lib.json')),
    );
    await store.load();
    dir = await ws.newWorkDir();
  });

  Future<String> textPdf(String name, String text) async {
    final out = p.join(dir.path, name);
    await api.textToPdf(text, out);
    return out;
  }

  Future<int> pdfiumPageCount(String path, {String? password}) async {
    final doc = await PdfDocument.openFile(path, passwordProvider: createSimplePasswordProvider(password));
    try {
      return doc.pages.length;
    } finally {
      await doc.dispose();
    }
  }

  Future<String> pdfiumText(String path, int page) async {
    final doc = await PdfDocument.openFile(path);
    try {
      return (await doc.pages[page].loadStructuredText()).fullText;
    } finally {
      await doc.dispose();
    }
  }

  testWidgets('image: resize -> compress -> save -> reopen -> verify dimensions and size', (tester) async {
    final src = img.Image(width: 3000, height: 2000);
    for (var y = 0; y < src.height; y += 4) {
      for (var x = 0; x < src.width; x += 4) {
        img.fillRect(
          src,
          x1: x,
          y1: y,
          x2: x + 3,
          y2: y + 3,
          color: img.ColorRgb8((x * 7) % 256, (y * 3) % 256, (x + y) % 256),
        );
      }
    }
    final input = img.encodeJpg(src, quality: 95);
    final r = await processImage(
      input,
      const ImageSpec(format: ImgFormat.jpeg, resize: ResizeSpec(width: 1200, height: 1200), targetBytes: 150 * 1024),
    );
    final tmp = File(p.join(dir.path, 'resized.jpg'))..writeAsBytesSync(r.bytes);
    final saved = await store.add(tmp, name: 'resized.jpg');
    final reopened = await store.fileOf(saved.entry).readAsBytes();
    final probe = probeImage(reopened);
    expect((probe.width, probe.height), (1200, 800));
    expect(reopened.length, lessThanOrEqualTo(150 * 1024));
    expect(r.targetMet, isTrue);

    // ... and into a PDF, verified by both engines.
    final pdf = p.join(dir.path, 'photo.pdf');
    await api.imagesToPdf([store.fileOf(saved.entry).path], pdf);
    expect((await api.pdfInfo(pdf)).pageCount, 1);
    expect(await pdfiumPageCount(pdf), 1);
  });

  testWidgets('PDF: merge -> reopen -> all pages present in order', (tester) async {
    final a = await textPdf('a.pdf', List.generate(120, (i) => 'Alpha line $i').join('\n'));
    final b = await textPdf('b.pdf', 'Bravo document');
    final aPages = (await api.pdfInfo(a)).pageCount;
    final out = p.join(dir.path, 'merged.pdf');
    await api.merge([(path: a, password: null), (path: b, password: null)], out);
    expect((await api.pdfInfo(out)).pageCount, aPages + 1);
    expect(await pdfiumPageCount(out), aPages + 1);
    expect(await pdfiumText(out, 0), contains('Alpha line 0'));
    expect(await pdfiumText(out, aPages), contains('Bravo document'));
  });

  testWidgets('PDF: add signature -> save -> reopen -> signature at the placed position', (tester) async {
    final src = await textPdf('to_sign.pdf', 'Please sign below');
    final sig = img.Image(width: 300, height: 100, numChannels: 4);
    img.fill(sig, color: img.ColorRgba8(0, 0, 0, 0));
    img.fillRect(sig, x1: 0, y1: 40, x2: 299, y2: 60, color: img.ColorRgba8(10, 20, 80, 255));
    final sigPath = p.join(dir.path, 'sig.png');
    File(sigPath).writeAsBytesSync(img.encodePng(sig));
    final out = p.join(dir.path, 'signed.pdf');
    // 150 x 50 pt box with its top-left at (300, 600) on an A4 page.
    await api.applyEdits(src, null, out, [
      {'type': 'image', 'page': 0, 'x': 300.0, 'y': 600.0, 'w': 150.0, 'h': 50.0, 'path': sigPath, 'rotation': 0.0},
    ]);
    expect(await pdfiumPageCount(out), 1);
    final png = await api.renderPage(out, null, 0, 595, p.join(dir.path, 'signed.png'));
    final page = img.decodePng(File(png).readAsBytesSync())!;
    final s = page.width / 595.0;
    final ink = page.getPixel((375 * s).round(), (625 * s).round());
    final blank = page.getPixel((375 * s).round(), (700 * s).round());
    expect(ink.r < 80 && ink.b < 140, isTrue, reason: 'stroke rendered at the signature position');
    expect(blank.r > 230, isTrue, reason: 'nothing below the signature');
  });

  testWidgets('OCR: text image -> searchable PDF -> text can be found', (tester) async {
    // Render real text with the device's font engine.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 1600, 600), Paint()..color = Colors.white);
    final tp = TextPainter(
      text: const TextSpan(
        text: 'SNAPPDF INTEGRATION\nRECEIPT NUMBER 4821',
        style: TextStyle(color: Colors.black, fontSize: 80, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 1500);
    tp.paint(canvas, const Offset(60, 120));
    final image = await recorder.endRecording().toImage(1600, 600);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final pngPath = p.join(dir.path, 'ocr.png');
    File(pngPath).writeAsBytesSync(bytes);

    final out = p.join(dir.path, 'ocr.pdf');
    final r = await api.imagesToSearchablePdf([pngPath], out);
    expect(r.pages, 1);
    expect(r.text.toUpperCase(), contains('INTEGRATION'));
    final extracted = (await api.extractText(out)).join(' ');
    expect(extracted.toUpperCase(), contains('4821'));
    expect((await pdfiumText(out, 0)).toUpperCase(), contains('RECEIPT'), reason: 'searchable in PDFium too');
  });

  testWidgets('PDF: protect -> wrong password rejected -> unlock', (tester) async {
    final src = await textPdf('secret.pdf', 'Secret content');
    final locked = p.join(dir.path, 'locked.pdf');
    await api.protect({'path': src, 'output': locked, 'userPassword': 'pa55'});
    await expectLater(
      api.pdfInfo(locked),
      throwsA(isA<NativeError>().having((e) => e.code, 'code', NativeError.passwordRequired)),
    );
    await expectLater(
      api.pdfInfo(locked, password: 'nope'),
      throwsA(isA<NativeError>().having((e) => e.code, 'code', NativeError.wrongPassword)),
    );
    expect(await pdfiumPageCount(locked, password: 'pa55'), 1);
    final open = p.join(dir.path, 'open.pdf');
    await api.unlock(locked, 'pa55', open);
    expect((await api.pdfInfo(open)).encrypted, isFalse);
  });

  testWidgets('app shell runs on device: tabs and a tool screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWithValue(ws), libraryStoreProvider.overrideWithValue(store)],
        child: const SnapApp(handleIncoming: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Quick actions'), findsOneWidget);
    for (final tab in ['Tools', 'Files', 'Settings', 'Home']) {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Compress PDF').first);
    await tester.pumpAndSettle();
    expect(find.text('Compression level'), findsOneWidget);
  });
}

Uint8List bytesOf(String path) => File(path).readAsBytesSync();
