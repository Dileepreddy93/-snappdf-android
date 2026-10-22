import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snappdf/core/files/file_kind.dart';
import 'package:snappdf/core/util/page_ranges.dart';
import 'package:snappdf/features/batch/batch_workflow.dart';
import 'package:snappdf/features/editor/editor_model.dart';
import 'package:snappdf/features/organize/organizer_model.dart';
import 'package:snappdf/features/passport/passport_screen.dart';
import 'package:snappdf/features/signature/signature_processing.dart';
import 'package:snappdf/features/smartfix/smart_fix_plan.dart';
import 'package:snappdf/features/tools/tool_registry.dart';

void main() {
  group('page ranges', () {
    test('parses singles, ranges and open ends', () {
      expect(parsePageRanges('1-3, 5, 8-', 10), [
        [0, 1, 2],
        [4],
        [7, 8, 9],
      ]);
      expect(parsePageRanges('-2', 5), [
        [0, 1],
      ]);
      expect(parsePageRanges('4-2', 5), [
        [3, 2, 1],
      ]);
      expect(parsePageSelection('3,1-2,3', 5), [0, 1, 2]);
    });

    test('rejects invalid input with readable messages', () {
      expect(() => parsePageRanges('', 3), throwsFormatException);
      expect(() => parsePageRanges('0', 3), throwsA(predicate((e) => '$e'.contains('Page 0 does not exist'))));
      expect(() => parsePageRanges('5', 3), throwsFormatException);
      expect(() => parsePageRanges('a-b', 3), throwsFormatException);
      expect(() => parsePageRanges('-', 3), throwsFormatException);
    });

    test('formats and chunks', () {
      expect(formatPageSelection([0, 1, 2, 4, 6, 7]), '1-3, 5, 7-8');
      expect(chunkPages(5, 2), [
        [0, 1],
        [2, 3],
        [4],
      ]);
      expect(() => chunkPages(5, 0), throwsFormatException);
    });
  });

  group('organizer', () {
    test('rotate, duplicate, move, delete, insert, undo and redo', () {
      final m = OrganizerModel(3);
      expect(m.isModified, isFalse);
      m.rotate({1}, 90);
      expect(m.pages[1].rotate, 90);
      m.rotate({1}, -180);
      expect(m.pages[1].rotate, 270);
      m.duplicate({0});
      expect(m.pages.map((p) => p.index), [0, 0, 1, 2]);
      expect(m.pages[0].id, isNot(m.pages[1].id));
      m.move(3, 0);
      expect(m.pages.map((p) => p.index), [2, 0, 0, 1]);
      m.insertBlank(1, 300, 400);
      expect(m.pages[1].isBlank, isTrue);
      m.insertSource(1, 2, 6);
      expect(m.length, 7);
      expect(m.pages.last.source, 1);
      m.delete({m.pages.first.id});
      expect(m.length, 6);
      expect(m.isModified, isTrue);
      m.undo();
      expect(m.length, 7);
      m.redo();
      expect(m.length, 6);
      expect(() => m.delete(m.pages.map((p) => p.id).toSet()), throwsStateError);
    });

    test('serialises to engine arguments', () {
      final m = OrganizerModel(2)
        ..rotate({0}, 90)
        ..setCrop({1}, [0.1, 0, 0.1, 0])
        ..insertBlank(2, 595, 842);
      expect(m.toArgs(), [
        {'source': 0, 'page': 0, 'rotate': 90},
        {
          'source': 0,
          'page': 1,
          'rotate': 0,
          'crop': [0.1, 0, 0.1, 0],
        },
        {'blankWidth': 595.0, 'blankHeight': 842.0, 'rotate': 0},
      ]);
      expect(m.toArgs({m.pages[1].id}).length, 1);
    });
  });

  group('editor model', () {
    test('hit testing picks the topmost item on the page', () {
      final m = EditorModel();
      m.add(StampItem(m.newId(), 0, rect: const Rect.fromLTWH(10, 10, 100, 40), text: 'A', color: 0));
      m.add(RedactItem(m.newId(), 0, rect: const Rect.fromLTWH(50, 20, 100, 40)));
      m.add(RedactItem(m.newId(), 1, rect: const Rect.fromLTWH(0, 0, 500, 500)));
      expect(m.hitTest(0, const Offset(60, 30)), isA<RedactItem>());
      expect(m.hitTest(0, const Offset(15, 15)), isA<StampItem>());
      expect(m.hitTest(0, const Offset(400, 400)), isNull);
    });

    test('serialises edits in display points; redactions separately', () {
      final m = EditorModel();
      m.add(ImageItem(m.newId(), 2, rect: const Rect.fromLTWH(10, 20, 30, 40), path: '/s.png', rotation: 90));
      m.add(
        InkItem(
          m.newId(),
          0,
          strokes: const [
            [Offset(1, 2), Offset(3, 4)],
          ],
          color: 1,
          width: 2,
        ),
      );
      m.add(RedactItem(m.newId(), 1, rect: const Rect.fromLTRB(1, 2, 3, 4)));
      final edits = m.toEdits();
      expect(edits.length, 2);
      expect(edits[0], containsPair('type', 'image'));
      expect(edits[0], containsPair('rotation', 90.0));
      expect(edits[1]['strokes'], [
        [1.0, 2.0, 3.0, 4.0],
      ]);
      expect(m.redactions(), {
        1: [
          [1.0, 2.0, 3.0, 4.0],
        ],
      });
    });

    test('undo/redo and translation', () {
      final m = EditorModel();
      final item = NoteItem(m.newId(), 0, at: const Offset(5, 5), text: 'x');
      m.add(item);
      m.replace(item.translated(const Offset(10, 0)));
      expect((m.items.single as NoteItem).at, const Offset(15, 5));
      m.undo();
      expect((m.items.single as NoteItem).at, const Offset(5, 5));
      m.redo();
      m.remove(item.id);
      expect(m.isEmpty, isTrue);
    });

    test('geometry helpers clamp and keep aspect', () {
      expect(
        dragRect(const Offset(50, 50), const Offset(-10, 900), const Size(100, 200)),
        const Rect.fromLTRB(0, 50, 50, 200),
      );
      final r = resizeFromCorner(const Rect.fromLTWH(0, 0, 100, 50), const Offset(100, 0), aspect: 2);
      expect(r.size, const Size(200, 100));
    });
  });

  group('smart fix planning', () {
    test('validates requests', () {
      expect(
        validateFixRequest(const FixRequest(inputKind: FileKind.image, target: FixTarget.jpg, maxBytes: 200 * 1024)),
        isEmpty,
      );
      expect(
        validateFixRequest(const FixRequest(inputKind: FileKind.pdf, width: 100)).single,
        contains('apply to images'),
      );
      expect(
        validateFixRequest(const FixRequest(inputKind: FileKind.image, exactSize: true, width: 10)).single,
        contains('both width and height'),
      );
      expect(
        validateFixRequest(const FixRequest(inputKind: FileKind.image, pages: '1')).single,
        contains('only applies to PDFs'),
      );
      expect(
        validateFixRequest(const FixRequest(inputKind: FileKind.pdf, pages: '9', pageCount: 3)).single,
        contains('does not exist'),
      );
      expect(validateFixRequest(const FixRequest(inputKind: FileKind.other)), isNotEmpty);
    });

    test('describes the plan', () {
      final steps = describePlan(
        const FixRequest(
          inputKind: FileKind.pdf,
          target: FixTarget.jpg,
          pages: '1',
          width: 800,
          maxBytes: 100 * 1024,
          pageCount: 2,
        ),
      );
      expect(steps.first, 'Keep pages 1');
      expect(steps.join('\n'), contains('Render pages as JPG'));
      expect(steps.join('\n'), contains('at most 100 KB'));
      expect(steps.last, contains('Check'));
    });
  });

  test('batch rename patterns produce unique, safe names', () {
    final taken = <String>{};
    final d = DateTime(2026, 3, 7);
    expect(applyRenamePattern('{name}_{n}', 'IMG.jpg', 0, 'jpg', d, taken), 'IMG_1.jpg');
    expect(applyRenamePattern('scan-{date}', 'a.png', 1, 'webp', d, taken), 'scan-2026-03-07.webp');
    expect(applyRenamePattern('scan-{date}', 'b.png', 2, 'webp', d, taken), 'scan-2026-03-07 (2).webp');
    expect(applyRenamePattern('a/b', 'c.jpg', 3, 'jpg', d, taken), 'a_b.jpg');
    expect(applyRenamePattern('', 'photo.heic', 4, 'jpg', d, taken), 'photo.jpg');
  });

  group('signature cleanup', () {
    test('paper becomes transparent, ink is kept and cropped', () {
      final im = img.Image(width: 200, height: 100);
      img.fill(im, color: img.ColorRgb8(235, 232, 225)); // off-white paper
      img.fillRect(im, x1: 60, y1: 40, x2: 140, y2: 55, color: img.ColorRgb8(20, 20, 60)); // ink stroke
      final out = cleanSignatureImage(im, const SignatureCleanup(padding: 4, inkArgb: 0xFF0000FF));
      expect(out.width, lessThan(100), reason: 'cropped to the ink');
      expect(out.getPixel(0, 0).a, 0, reason: 'paper removed');
      final c = out.getPixel(out.width ~/ 2, out.height ~/ 2);
      expect(c.a, 255);
      expect(c.b, 255, reason: 'recoloured blue');
    });

    test('recolouring keeps alpha', () {
      final im = img.Image(width: 4, height: 4, numChannels: 4);
      im.setPixelRgba(1, 1, 0, 0, 0, 128);
      final out = recolorInk(im, 0xFFFF0000);
      expect(out.getPixel(1, 1).r, 255);
      expect(out.getPixel(1, 1).a, 128);
      expect(out.getPixel(0, 0).a, 0);
    });
  });

  group('passport photos', () {
    test('mm presets convert to pixels at the chosen dpi', () {
      expect(photoPresets.first.pixels(300), (413, 531));
      expect(const PhotoPreset('px', widthPx: 200, heightPx: 230).pixels(300), (200, 230));
    });

    test('print sheet places as many photos as fit', () {
      final photo = img.Image(width: 413, height: 531);
      final s = composeSheet(photo, 1800, 1200, gap: 24);
      expect(s.placed, 8); // 4 columns x 2 rows on 6x4 in at 300 dpi
      expect((s.sheet.width, s.sheet.height), (1800, 1200));
      expect(composeSheet(photo, 1800, 1200, count: 3).placed, 3);
    });
  });

  group('tool registry', () {
    test('ids are unique and search finds tools by task words', () {
      final ids = allTools.map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(searchTools('reduce size').map((t) => t.id), containsAll(['compress_pdf', 'compress_image']));
      expect(searchTools('password').map((t) => t.id), containsAll(['protect_pdf', 'unlock_pdf']));
      expect(searchTools('gps').single.id, 'image_metadata');
      expect(searchTools('zzzz'), isEmpty);
    });
  });
}
