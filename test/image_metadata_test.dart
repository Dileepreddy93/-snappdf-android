import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snappdf/features/image/engine/image_metadata.dart';

Uint8List jpegWithExif({int orientation = 1, bool gps = true}) {
  final im = img.Image(width: 32, height: 16);
  img.fill(im, color: img.ColorRgb8(10, 120, 200));
  im.exif.imageIfd['Make'] = img.IfdValueAscii('TestCam');
  im.exif.imageIfd['Model'] = img.IfdValueAscii('Model X');
  if (orientation != 1) im.exif.imageIfd.orientation = orientation;
  if (gps) {
    im.exif.gpsIfd[2] = img.IfdValueRational(17, 1);
  }
  return img.encodeJpg(im, quality: 90);
}

/// Bytes from the start-of-scan marker onward (the compressed pixel data).
Uint8List scanData(Uint8List jpeg) {
  for (var i = 2; i < jpeg.length - 1; i++) {
    if (jpeg[i] == 0xFF && jpeg[i + 1] == 0xDA) return jpeg.sublist(i);
  }
  throw StateError('no SOS');
}

void main() {
  test('reports EXIF tags and GPS presence', () {
    final r = inspectMetadata(jpegWithExif());
    expect(r.blocks.map((b) => b.kind), contains('EXIF'));
    expect(r.hasGps, isTrue);
    expect(r.tags['Make'], contains('TestCam'));
  });

  test('JPEG metadata removal is lossless and removes GPS', () {
    final src = jpegWithExif();
    final out = stripMetadataLossless(src);
    expect(out.length, lessThan(src.length));
    expect(scanData(out), scanData(src), reason: 'image data must be byte-identical');
    final r = inspectMetadata(out);
    expect(r.hasGps, isFalse);
    expect(r.tags.containsKey('Make'), isFalse);
    expect(img.decodeJpg(out), isNotNull);
  });

  test('keeps only the orientation so rotated photos stay upright', () {
    final out = stripMetadataLossless(jpegWithExif(orientation: 6));
    final exif = img.decodeJpgExif(out)!;
    expect(exif.imageIfd.orientation, 6);
    expect(exif.imageIfd['Make'], isNull);
    expect(inspectMetadata(out).hasGps, isFalse);
  });

  test('PNG text chunks are removed, pixels untouched', () {
    final im = img.Image(width: 4, height: 4);
    im.addTextData({'Author': 'Someone', 'Comment': 'secret'});
    final src = img.encodePng(im);
    expect(inspectMetadata(src).blocks.map((b) => b.kind), contains('Text'));
    final out = stripMetadataLossless(src);
    expect(inspectMetadata(out).blocks, isEmpty);
    expect(String.fromCharCodes(out).contains('secret'), isFalse);
    final a = img.decodePng(src)!, b = img.decodePng(out)!;
    expect(b.getPixel(2, 2), a.getPixel(2, 2));
  });

  test('WebP EXIF chunk is removed and the file stays valid', () {
    final im = img.Image(width: 8, height: 8);
    im.exif.imageIfd['Make'] = img.IfdValueAscii('WebCam');
    final src = img.encodeWebP(im);
    final before = inspectMetadata(src);
    final out = stripMetadataLossless(src);
    expect(inspectMetadata(out).blocks.where((b) => b.kind == 'EXIF'), isEmpty);
    expect(img.decodeWebP(out), isNotNull);
    if (before.blocks.any((b) => b.kind == 'EXIF')) {
      expect(out.length, lessThan(src.length));
    }
  });
}
