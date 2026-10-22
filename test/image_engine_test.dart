import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snappdf/features/image/engine/image_engine.dart';
import 'package:snappdf/features/image/engine/image_format.dart';

/// Photo-like content (gradients + noise) that does not compress trivially.
img.Image photo(int w, int h, {int seed = 1}) {
  final r = math.Random(seed);
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(
        x,
        y,
        (x * 255 ~/ w + r.nextInt(50)).clamp(0, 255),
        (y * 255 ~/ h + r.nextInt(50)).clamp(0, 255),
        r.nextInt(256),
      );
    }
  }
  return im;
}

ImageProbe probe(Uint8List b) => probeImage(b);

void main() {
  group('formats', () {
    test('sniffs JPEG, PNG and WebP from bytes, not extensions', () {
      final im = photo(20, 10);
      expect(ImgFormat.sniff(img.encodeJpg(im)), ImgFormat.jpeg);
      expect(ImgFormat.sniff(img.encodePng(im)), ImgFormat.png);
      expect(ImgFormat.sniff(img.encodeWebP(im, lossless: false)), ImgFormat.webp);
      expect(ImgFormat.sniff(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });

    test('converts between formats and reports the real output format', () {
      final png = img.encodePng(photo(64, 48));
      for (final f in ImgFormat.values) {
        final r = processImageSync(png, ImageSpec(format: f, quality: 80));
        expect(ImgFormat.sniff(r.bytes), f);
        expect(r.format, f);
        final p = probe(r.bytes);
        expect((p.width, p.height), (64, 48));
      }
    });

    test('rejects data that is not an image', () {
      expect(
        () => processImageSync(Uint8List.fromList(List.filled(100, 7)), const ImageSpec()),
        throwsA(isA<ImageEngineException>()),
      );
    });
  });

  group('resize', () {
    final src = img.encodePng(photo(400, 200));

    test('fit keeps aspect ratio inside the box', () {
      final r = processImageSync(src, const ImageSpec(resize: ResizeSpec(width: 100, height: 100)));
      expect((r.width, r.height), (100, 50));
    });

    test('fill produces exactly the requested size', () {
      final r = processImageSync(
        src,
        const ImageSpec(resize: ResizeSpec(width: 120, height: 120, mode: ResizeMode.fill)),
      );
      expect((r.width, r.height), (120, 120));
    });

    test('stretch ignores aspect ratio', () {
      final r = processImageSync(
        src,
        const ImageSpec(resize: ResizeSpec(width: 50, height: 300, mode: ResizeMode.stretch)),
      );
      expect((r.width, r.height), (50, 300));
    });

    test('pad keeps the image undistorted on an exact canvas with transparency', () {
      final r = processImageSync(
        src,
        const ImageSpec(
          format: ImgFormat.png,
          resize: ResizeSpec(width: 200, height: 200, mode: ResizeMode.pad),
        ),
      );
      expect((r.width, r.height), (200, 200));
      final out = img.decodePng(r.bytes)!;
      expect(out.getPixel(100, 10).a, 0, reason: 'top margin is transparent');
      expect(out.getPixel(100, 100).a, 255, reason: 'centre is the image');
    });

    test('percentage scaling', () {
      final r = processImageSync(src, const ImageSpec(resize: ResizeSpec(percent: 25)));
      expect((r.width, r.height), (100, 50));
    });

    test('fit does not enlarge small images unless allowed', () {
      final r = processImageSync(src, const ImageSpec(resize: ResizeSpec(width: 800, height: 800)));
      expect(r.width, 400);
      expect(r.notes.join(), contains('not enlarged'));
    });
  });

  group('geometry', () {
    test('crop, rotate and flip', () {
      final im = img.Image(width: 30, height: 20);
      img.fill(im, color: img.ColorRgb8(255, 255, 255));
      img.fillRect(im, x1: 0, y1: 0, x2: 9, y2: 9, color: img.ColorRgb8(255, 0, 0)); // red top-left
      final src = img.encodePng(im);
      final rotated = img.decodePng(processImageSync(src, const ImageSpec(format: ImgFormat.png, rotate: 90)).bytes)!;
      expect((rotated.width, rotated.height), (20, 30));
      expect(rotated.getPixel(rotated.width - 2, 1).r, 255, reason: 'top-left moves to top-right');
      expect(rotated.getPixel(rotated.width - 2, 1).g, 0);
      final flipped = img.decodePng(processImageSync(src, const ImageSpec(format: ImgFormat.png, flipH: true)).bytes)!;
      expect(flipped.getPixel(28, 1).g, 0, reason: 'red moved to the right');
      final cropped = processImageSync(src, const ImageSpec(format: ImgFormat.png, crop: CropRect(0, 0, 10, 10)));
      expect((cropped.width, cropped.height), (10, 10));
    });

    test('EXIF orientation is applied so pixels are upright', () {
      final im = img.Image(width: 40, height: 20);
      img.fill(im, color: img.ColorRgb8(0, 0, 255));
      img.fillRect(im, x1: 0, y1: 0, x2: 19, y2: 19, color: img.ColorRgb8(255, 0, 0)); // left half red
      im.exif.imageIfd.orientation = 6; // rotate 90 CW to display
      final jpg = img.encodeJpg(im, quality: 95);
      expect(img.decodeJpgExif(jpg)!.imageIfd.orientation, 6);
      final p = probe(jpg);
      expect((p.width, p.height), (20, 40), reason: 'dimensions are reported upright');
      final out = img.decodePng(processImageSync(jpg, const ImageSpec(format: ImgFormat.png)).bytes)!;
      expect(out.getPixel(10, 5).r > 200, isTrue, reason: 'red (left) is now on top');
      expect(out.getPixel(10, 35).b > 200, isTrue);
    });
  });

  group('transparency', () {
    img.Image withAlpha() {
      final im = img.Image(width: 40, height: 40, numChannels: 4);
      img.fill(im, color: img.ColorRgba8(0, 0, 0, 0));
      img.fillCircle(im, x: 20, y: 20, radius: 10, color: img.ColorRgba8(0, 0, 0, 255));
      return im;
    }

    test('PNG and WebP keep transparency', () {
      final src = img.encodePng(withAlpha());
      expect(probe(src).hasAlpha, isTrue);
      expect(probe(processImageSync(src, const ImageSpec(format: ImgFormat.png)).bytes).hasAlpha, isTrue);
      final webp = processImageSync(src, const ImageSpec(format: ImgFormat.webp, quality: 90));
      expect(img.decodeWebP(webp.bytes)!.getPixel(1, 1).a, lessThan(10));
    });

    test('JPEG flattens transparency onto the chosen background and says so', () {
      final src = img.encodePng(withAlpha());
      final r = processImageSync(src, const ImageSpec(format: ImgFormat.jpeg, background: 0xFFFF0000));
      final out = img.decodeJpg(r.bytes)!;
      expect(out.getPixel(1, 1).r, greaterThan(200));
      expect(out.getPixel(1, 1).g, lessThan(60));
      expect(r.notes.join(), contains('transparency'));
    });

    test('mask replaces the background', () {
      final src = img.encodePng(photo(20, 20));
      final mask = img.Image(width: 20, height: 20);
      img.fill(mask, color: img.ColorRgb8(0, 0, 0));
      img.fillRect(mask, x1: 5, y1: 5, x2: 14, y2: 14, color: img.ColorRgb8(255, 255, 255));
      final r = processImageSync(
        src,
        ImageSpec(format: ImgFormat.png, mask: img.encodePng(mask), maskBackground: 0xFF00FF00),
      );
      final out = img.decodePng(r.bytes)!;
      expect(out.getPixel(1, 1).g, 255);
      expect(out.getPixel(1, 1).r, 0);
      final t = processImageSync(src, ImageSpec(format: ImgFormat.png, mask: img.encodePng(mask)));
      expect(img.decodePng(t.bytes)!.getPixel(1, 1).a, 0);
      expect(img.decodePng(t.bytes)!.getPixel(10, 10).a, 255);
    });
  });

  group('target file size', () {
    final big = img.encodePng(photo(1200, 900));

    test('meets a JPEG limit and stays at or below it', () {
      const target = 60 * 1024;
      final r = processImageSync(big, const ImageSpec(format: ImgFormat.jpeg, quality: 92, targetBytes: target));
      expect(r.targetMet, isTrue);
      expect(r.bytes.length, lessThanOrEqualTo(target));
      expect(probe(r.bytes).width, r.width);
    });

    test('meets a WebP limit', () {
      const target = 40 * 1024;
      final r = processImageSync(big, const ImageSpec(format: ImgFormat.webp, targetBytes: target));
      expect(r.targetMet, isTrue);
      expect(r.bytes.length, lessThanOrEqualTo(target));
    });

    test('downscales when quality alone cannot reach the limit', () {
      const target = 8 * 1024;
      final r = processImageSync(big, const ImageSpec(format: ImgFormat.jpeg, targetBytes: target));
      expect(r.targetMet, isTrue);
      expect(r.bytes.length, lessThanOrEqualTo(target));
      expect(r.width, lessThan(1200));
      expect(r.notes.join(), contains('Dimensions reduced'));
    });

    test('with fixed dimensions, an impossible limit is reported, never faked', () {
      const target = 1024; // 1 KB for 1200x900 noise: impossible
      final r = processImageSync(
        big,
        const ImageSpec(
          format: ImgFormat.jpeg,
          targetBytes: target,
          resize: ResizeSpec(width: 1200, height: 900, mode: ResizeMode.stretch),
        ),
      );
      expect(r.targetMet, isFalse);
      expect(r.bytes.length, greaterThan(target));
      expect((r.width, r.height), (1200, 900), reason: 'exact dimensions are respected');
      expect(r.notes.join(), contains('Could not reach'));
    });

    test('PNG limits use palette reduction before shrinking', () {
      final src = img.encodePng(photo(300, 300));
      final paletteSize = img.encodePng(img.quantize(img.decodePng(src)!, numberOfColors: 256), level: 9).length;
      final r = processImageSync(src, ImageSpec(format: ImgFormat.png, targetBytes: paletteSize + 100));
      expect(r.targetMet, isTrue);
      expect((r.width, r.height), (300, 300));
    });
  });

  group('adjustments', () {
    test('brightness changes pixel values; identity leaves them', () {
      final im = img.Image(width: 8, height: 8);
      img.fill(im, color: img.ColorRgb8(100, 100, 100));
      final src = img.encodePng(im);
      final brighter = img.decodePng(
        processImageSync(src, const ImageSpec(format: ImgFormat.png, adjust: Adjustments(brightness: 0.5))).bytes,
      )!;
      expect(brighter.getPixel(4, 4).r, greaterThan(120));
      final same = img.decodePng(processImageSync(src, const ImageSpec(format: ImgFormat.png)).bytes)!;
      expect(same.getPixel(4, 4).r, 100);
      final gray = img.decodePng(
        processImageSync(
          img.encodePng(photo(16, 16)),
          const ImageSpec(format: ImgFormat.png, adjust: Adjustments(saturation: -1)),
        ).bytes,
      )!;
      final p = gray.getPixel(5, 5);
      expect((p.r - p.g).abs() <= 2 && (p.g - p.b).abs() <= 2, isTrue, reason: 'fully desaturated');
    });
  });
}
