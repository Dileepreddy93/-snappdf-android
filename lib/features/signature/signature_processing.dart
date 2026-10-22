import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../image/engine/image_engine.dart';

/// Turns a photo/scan of a signature on paper into transparent ink.
///
/// Pixels darker than [threshold] (0..255 luminance) become ink; a soft
/// ramp of [softness] levels keeps edges smooth. With [inkArgb], ink is
/// recoloured; otherwise original colours are kept. The result is cropped to
/// the ink plus [padding] pixels.
class SignatureCleanup {
  const SignatureCleanup({this.threshold = 150, this.softness = 40, this.inkArgb, this.padding = 8, this.crop = true});
  final int threshold;
  final int softness;
  final int? inkArgb;
  final int padding;
  final bool crop;
}

img.Image cleanSignatureImage(img.Image src, SignatureCleanup o) {
  // Normalise lighting: estimate paper brightness from the 90th percentile.
  final hist = List<int>.filled(256, 0);
  for (final p in src) {
    hist[((0.299 * p.r + 0.587 * p.g + 0.114 * p.b) / p.maxChannelValue * 255).round().clamp(0, 255)]++;
  }
  var acc = 0;
  var paper = 255;
  final target = (src.width * src.height * 0.9).round();
  for (var i = 0; i < 256; i++) {
    acc += hist[i];
    if (acc >= target) {
      paper = i;
      break;
    }
  }
  final scale = paper > 40 ? 255 / paper : 1.0;

  final out = img.Image(width: src.width, height: src.height, numChannels: 4);
  var minX = src.width, minY = src.height, maxX = -1, maxY = -1;
  final ir = o.inkArgb != null ? (o.inkArgb! >> 16) & 0xFF : null;
  final ig = o.inkArgb != null ? (o.inkArgb! >> 8) & 0xFF : null;
  final ib = o.inkArgb != null ? o.inkArgb! & 0xFF : null;
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      final max = p.maxChannelValue;
      final r = p.r / max * 255, g = p.g / max * 255, b = p.b / max * 255;
      final lum = ((0.299 * r + 0.587 * g + 0.114 * b) * scale).clamp(0, 255);
      final srcAlpha = p.a / max;
      // alpha 1 at (threshold - softness) and darker, 0 at threshold and lighter.
      final a = ((o.threshold - lum) / math.max(1, o.softness)).clamp(0.0, 1.0) * srcAlpha;
      if (a <= 0) {
        out.setPixelRgba(x, y, 0, 0, 0, 0);
        continue;
      }
      out.setPixelRgba(x, y, ir ?? r.round(), ig ?? g.round(), ib ?? b.round(), (a * 255).round());
      if (a > 0.25) {
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (!o.crop || maxX < 0) return out;
  final l = math.max(0, minX - o.padding);
  final t = math.max(0, minY - o.padding);
  final r = math.min(src.width - 1, maxX + o.padding);
  final b = math.min(src.height - 1, maxY + o.padding);
  return img.copyCrop(out, x: l, y: t, width: r - l + 1, height: b - t + 1);
}

/// Recolours the opaque pixels of a transparent signature, keeping alpha.
img.Image recolorInk(img.Image src, int argb) {
  final out = src.hasAlpha ? src.clone() : src.convert(numChannels: 4);
  final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
  for (final p in out) {
    if (p.a > 0) {
      p
        ..r = r * p.maxChannelValue / 255
        ..g = g * p.maxChannelValue / 255
        ..b = b * p.maxChannelValue / 255;
    }
  }
  return out;
}

/// Imported image -> transparent PNG of the ink only.
Future<Uint8List> cleanSignature(Uint8List bytes, SignatureCleanup o) => Isolate.run(() {
  final src = decodeUpright(bytes);
  // Work at a sensible size: signatures do not need more than 2000 px.
  final scaled = math.max(src.width, src.height) > 2000
      ? img.copyResize(
          src,
          width: src.width >= src.height ? 2000 : null,
          height: src.height > src.width ? 2000 : null,
          interpolation: img.Interpolation.average,
        )
      : src;
  return img.encodePng(cleanSignatureImage(scaled, o));
});

Future<Uint8List> recolorSignature(Uint8List png, int argb) =>
    Isolate.run(() => img.encodePng(recolorInk(img.decodePng(png)!, argb)));
