import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'image_format.dart';

/// Largest image (in pixels) the engine will decode, ~ 200 MB of RGBA.
const int kMaxImagePixels = 50 * 1000 * 1000;

class ImageEngineException implements Exception {
  ImageEngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum ResizeMode {
  /// Fit inside width x height, keeping the aspect ratio.
  fit,

  /// Fill width x height exactly, cropping the overflow (centred).
  fill,

  /// Exactly width x height, distorting if the aspect ratio differs.
  stretch,
}

class ResizeSpec {
  const ResizeSpec({
    this.width,
    this.height,
    this.percent,
    this.mode = ResizeMode.fit,
    this.allowUpscale = false,
  });

  final int? width;
  final int? height;

  /// Scale factor in percent; used when width/height are null.
  final double? percent;
  final ResizeMode mode;
  final bool allowUpscale;

  /// Output dimensions are fixed exactly by the user.
  bool get isExact =>
      width != null &&
      height != null &&
      (mode == ResizeMode.fill || mode == ResizeMode.stretch);

  Map<String, Object?> toJson() => {
        'width': width,
        'height': height,
        'percent': percent,
        'mode': mode.name,
        'allowUpscale': allowUpscale,
      };

  factory ResizeSpec.fromJson(Map<String, Object?> j) => ResizeSpec(
        width: j['width'] as int?,
        height: j['height'] as int?,
        percent: (j['percent'] as num?)?.toDouble(),
        mode: ResizeMode.values.byName(j['mode'] as String? ?? 'fit'),
        allowUpscale: j['allowUpscale'] as bool? ?? false,
      );
}

/// Crop rectangle in pixels of the upright (EXIF-corrected) source image.
class CropRect {
  const CropRect(this.x, this.y, this.width, this.height);
  final int x;
  final int y;
  final int width;
  final int height;
}

class Adjustments {
  const Adjustments({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.sharpness = 0,
  });

  /// -1..1, 0 = unchanged.
  final double brightness;
  final double contrast;
  final double saturation;

  /// 0..1, 0 = unchanged.
  final double sharpness;

  bool get isIdentity =>
      brightness == 0 && contrast == 0 && saturation == 0 && sharpness == 0;
}

/// A pre-rendered overlay (e.g. a text watermark drawn with Flutter) placed
/// at a fractional position of the output image.
class Overlay {
  const Overlay({
    required this.rgba,
    required this.width,
    required this.height,
    this.centerX = 0.5,
    this.centerY = 0.5,
    this.widthFraction = 0.5,
    this.tile = false,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final double centerX;
  final double centerY;

  /// Overlay width as a fraction of the output width.
  final double widthFraction;
  final bool tile;
}

/// Everything that should happen to one image.
class ImageSpec {
  const ImageSpec({
    this.format,
    this.quality = 90,
    this.targetBytes,
    this.resize,
    this.crop,
    this.rotate = 0,
    this.flipH = false,
    this.flipV = false,
    this.adjust = const Adjustments(),
    this.background = 0xFFFFFFFF,
    this.overlay,
    this.mask,
    this.maskBackground,
    this.allowDownscaleForSize = true,
    this.minQuality = 30,
  });

  /// Output format; null keeps the input format (or JPEG for unsupported ones).
  final ImgFormat? format;

  /// 1..100 for lossy formats.
  final int quality;

  /// Maximum output size in bytes, if any.
  final int? targetBytes;
  final ResizeSpec? resize;
  final CropRect? crop;

  /// Clockwise degrees: 0, 90, 180 or 270.
  final int rotate;
  final bool flipH;
  final bool flipV;
  final Adjustments adjust;

  /// ARGB used where transparency must be flattened (e.g. JPEG output).
  final int background;
  final Overlay? overlay;

  /// Optional alpha mask (PNG bytes, white = keep) applied before resizing,
  /// e.g. a person segmentation mask for background replacement.
  final Uint8List? mask;

  /// When set, masked-out areas are filled with this ARGB colour instead of
  /// becoming transparent.
  final int? maskBackground;

  /// When a size target cannot be met at [minQuality], shrink dimensions.
  final bool allowDownscaleForSize;

  /// Lowest quality the size search may use before resorting to downscaling.
  final int minQuality;
}

class ImageResult {
  ImageResult({
    required this.bytes,
    required this.width,
    required this.height,
    required this.format,
    required this.quality,
    required this.targetMet,
    required this.notes,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final ImgFormat format;
  final int? quality;

  /// False when [ImageSpec.targetBytes] could not be reached.
  final bool targetMet;
  final List<String> notes;
}

class ImageProbe {
  ImageProbe(this.width, this.height, this.format, this.hasAlpha,
      this.orientation);
  final int width;
  final int height;
  final ImgFormat? format;
  final bool hasAlpha;
  final int orientation;
}

/// Decodes and applies EXIF orientation, so pixels are upright.
img.Image decodeUpright(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  if (decoder == null) {
    throw ImageEngineException('This file is not a supported image.');
  }
  final info = decoder.startDecode(bytes);
  if (info != null && info.width * info.height > kMaxImagePixels) {
    throw ImageEngineException(
        'This image is too large (${info.width} x ${info.height}).');
  }
  final image = decoder.decode(bytes, frame: 0);
  if (image == null) {
    throw ImageEngineException('The image could not be decoded.');
  }
  if (image.exif.imageIfd.hasOrientation &&
      image.exif.imageIfd.orientation != 1) {
    return img.bakeOrientation(image);
  }
  return image;
}

ImageProbe probeImage(Uint8List bytes) {
  final image = decodeUpright(bytes);
  final format = ImgFormat.sniff(bytes);
  return ImageProbe(
    image.width,
    image.height,
    format,
    image.hasAlpha && _anyTransparent(image),
    1,
  );
}

bool _anyTransparent(img.Image image) {
  if (!image.hasAlpha) return false;
  // Sample on a grid; enough to tell "uses transparency" for UI hints.
  final stepX = math.max(1, image.width ~/ 64);
  final stepY = math.max(1, image.height ~/ 64);
  for (var y = 0; y < image.height; y += stepY) {
    for (var x = 0; x < image.width; x += stepX) {
      if (image.getPixel(x, y).a < image.maxChannelValue) return true;
    }
  }
  return false;
}

/// Runs [processImageSync] on a background isolate.
Future<ImageResult> processImage(Uint8List input, ImageSpec spec) =>
    Isolate.run(() => processImageSync(input, spec));

ImageResult processImageSync(Uint8List input, ImageSpec spec) {
  final notes = <String>[];
  var image = decodeUpright(input);
  final inputFormat = ImgFormat.sniff(input);
  final format = spec.format ?? inputFormat ?? ImgFormat.jpeg;

  if (spec.mask != null) {
    image = _applyMask(image, spec.mask!, spec.maskBackground);
  }
  if (spec.crop != null) {
    final c = spec.crop!;
    final x = c.x.clamp(0, image.width - 1);
    final y = c.y.clamp(0, image.height - 1);
    final w = c.width.clamp(1, image.width - x);
    final h = c.height.clamp(1, image.height - y);
    image = img.copyCrop(image, x: x, y: y, width: w, height: h);
  }
  final rot = ((spec.rotate % 360) + 360) % 360;
  if (rot != 0) {
    image = img.copyRotate(image, angle: rot);
  }
  if (spec.flipH) image = img.flipHorizontal(image);
  if (spec.flipV) image = img.flipVertical(image);
  if (spec.resize != null) {
    image = applyResize(image, spec.resize!, notes);
  }
  if (!spec.adjust.isIdentity) {
    image = applyAdjustments(image, spec.adjust);
  }
  if (spec.overlay != null) {
    image = _applyOverlay(image, spec.overlay!);
  }
  if (!format.alpha && image.hasAlpha) {
    image = flattenAlpha(image, spec.background);
    if (inputFormat != null && inputFormat.alpha && _anyTransparent(image)) {
      notes.add('Transparent areas were filled because ${format.label} '
          'does not support transparency.');
    }
  }

  return encodeWithTarget(image, format, spec, notes);
}

img.Image applyResize(img.Image image, ResizeSpec r, List<String> notes) {
  int? w = r.width;
  int? h = r.height;
  if (w == null && h == null) {
    if (r.percent == null) return image;
    final f = r.percent! / 100.0;
    w = math.max(1, (image.width * f).round());
    h = math.max(1, (image.height * f).round());
    return img.copyResize(image,
        width: w, height: h, interpolation: img.Interpolation.cubic);
  }
  if (w != null && w <= 0 || h != null && h <= 0) {
    throw ImageEngineException('Width and height must be positive.');
  }
  if (w != null && h != null && w * h > kMaxImagePixels) {
    throw ImageEngineException('The requested size is too large.');
  }
  switch (r.mode) {
    case ResizeMode.stretch:
      w ??= (image.width * h! / image.height).round();
      h ??= (image.height * w / image.width).round();
      if (!r.allowUpscale && (w > image.width || h > image.height)) {
        notes.add('The image was enlarged; it may look soft.');
      }
      return img.copyResize(image,
          width: w, height: h, interpolation: img.Interpolation.cubic);
    case ResizeMode.fill:
      if (w == null || h == null) {
        return applyResize(
            image, ResizeSpec(width: w, height: h, mode: ResizeMode.fit,
                allowUpscale: r.allowUpscale), notes);
      }
      final scale = math.max(w / image.width, h / image.height);
      final sw = math.max(w, (image.width * scale).round());
      final sh = math.max(h, (image.height * scale).round());
      final scaled = img.copyResize(image,
          width: sw, height: sh, interpolation: img.Interpolation.cubic);
      return img.copyCrop(scaled,
          x: (sw - w) ~/ 2, y: (sh - h) ~/ 2, width: w, height: h);
    case ResizeMode.fit:
      final scale = math.min(
        w != null ? w / image.width : double.infinity,
        h != null ? h / image.height : double.infinity,
      );
      if (scale >= 1 && !r.allowUpscale) {
        if (scale > 1) {
          notes.add('Already smaller than the requested size; not enlarged.');
        }
        return image;
      }
      return img.copyResize(image,
          width: math.max(1, (image.width * scale).round()),
          height: math.max(1, (image.height * scale).round()),
          interpolation: img.Interpolation.cubic);
  }
}

img.Image applyAdjustments(img.Image image, Adjustments a) {
  var out = image;
  if (a.brightness != 0 || a.contrast != 0 || a.saturation != 0) {
    out = img.adjustColor(
      out,
      brightness: a.brightness == 0 ? null : 1 + a.brightness * 0.6,
      contrast: a.contrast == 0 ? null : 1 + a.contrast * 0.8,
      saturation: a.saturation == 0 ? null : 1 + a.saturation,
    );
  }
  if (a.sharpness > 0) {
    // Unsharp-style 3x3 kernel blended by amount.
    out = img.convolution(out,
        filter: const [0, -1, 0, -1, 5, -1, 0, -1, 0],
        amount: a.sharpness.clamp(0, 1));
  }
  return out;
}

img.Image flattenAlpha(img.Image image, int argb) {
  final bg = img.Image(
      width: image.width, height: image.height, numChannels: 3);
  img.fill(bg,
      color: img.ColorRgb8((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF));
  return img.compositeImage(bg, image);
}

img.Image _applyMask(img.Image image, Uint8List maskPng, int? background) {
  var mask = img.decodePng(maskPng);
  if (mask == null) throw ImageEngineException('Invalid mask.');
  if (mask.width != image.width || mask.height != image.height) {
    mask = img.copyResize(mask,
        width: image.width,
        height: image.height,
        interpolation: img.Interpolation.linear);
  }
  final out = img.Image(
      width: image.width, height: image.height, numChannels: 4);
  final br = background != null ? (background >> 16) & 0xFF : 0;
  final bgG = background != null ? (background >> 8) & 0xFF : 0;
  final bb = background != null ? background & 0xFF : 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      final m = mask.getPixel(x, y).r / mask.maxChannelValue;
      final r = p.r / p.maxChannelValue * 255;
      final g = p.g / p.maxChannelValue * 255;
      final b = p.b / p.maxChannelValue * 255;
      if (background != null) {
        out.setPixelRgba(
          x,
          y,
          (r * m + br * (1 - m)).round(),
          (g * m + bgG * (1 - m)).round(),
          (b * m + bb * (1 - m)).round(),
          255,
        );
      } else {
        final a = p.a / p.maxChannelValue * 255 * m;
        out.setPixelRgba(x, y, r.round(), g.round(), b.round(), a.round());
      }
    }
  }
  return out;
}

img.Image _applyOverlay(img.Image image, Overlay o) {
  final overlay = img.Image.fromBytes(
      width: o.width,
      height: o.height,
      bytes: o.rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba);
  final targetW = math.max(1, (image.width * o.widthFraction).round());
  final targetH = math.max(1, (o.height * targetW / o.width).round());
  final scaled = img.copyResize(overlay,
      width: targetW, height: targetH, interpolation: img.Interpolation.cubic);
  final base = image.hasAlpha ? image : image.convert(numChannels: 4);
  if (o.tile) {
    final stepX = (targetW * 1.6).round();
    final stepY = (targetH * 3).round();
    var row = 0;
    for (var y = -targetH; y < base.height; y += stepY, row++) {
      final offset = row.isOdd ? stepX ~/ 2 : 0;
      for (var x = -targetW + offset; x < base.width; x += stepX) {
        img.compositeImage(base, scaled, dstX: x, dstY: y);
      }
    }
  } else {
    final x = (base.width * o.centerX - targetW / 2).round();
    final y = (base.height * o.centerY - targetH / 2).round();
    img.compositeImage(base, scaled, dstX: x, dstY: y);
  }
  return base;
}

Uint8List encodeImage(img.Image image, ImgFormat format, int quality) {
  switch (format) {
    case ImgFormat.jpeg:
      final opaque = image.hasAlpha ? flattenAlpha(image, 0xFFFFFFFF) : image;
      return img.encodeJpg(opaque,
          quality: quality.clamp(1, 100),
          chroma: quality >= 90 ? img.JpegChroma.yuv444 : img.JpegChroma.yuv420);
    case ImgFormat.png:
      return img.encodePng(image, level: 9);
    case ImgFormat.webp:
      return img.encodeWebP(image, lossless: false, quality: quality.clamp(1, 100));
  }
}

/// Encodes [image], searching quality and (if allowed) dimensions so the
/// output does not exceed [ImageSpec.targetBytes]. Never claims success when
/// the target was not reached.
ImageResult encodeWithTarget(
    img.Image image, ImgFormat format, ImageSpec spec, List<String> notes) {
  final target = spec.targetBytes;
  Uint8List bytes = encodeImage(image, format, spec.quality);
  if (target == null || bytes.length <= target) {
    return ImageResult(
      bytes: bytes,
      width: image.width,
      height: image.height,
      format: format,
      quality: format.lossy ? spec.quality : null,
      targetMet: true,
      notes: notes,
    );
  }

  final canScale =
      spec.allowDownscaleForSize && !(spec.resize?.isExact ?? false);
  var current = image;
  var best = _Candidate(bytes, image, spec.quality);

  if (format.lossy) {
    for (var round = 0; round < 6; round++) {
      final found = _searchQuality(current, format, target, spec.minQuality,
          math.min(spec.quality, 95));
      if (found != null) {
        if (found.quality < spec.quality) {
          notes.add('Quality reduced to ${found.quality} to meet the size limit.');
        }
        if (current.width != image.width) {
          notes.add('Dimensions reduced from ${image.width} x ${image.height} '
              'to ${current.width} x ${current.height} to meet the size limit.');
        }
        return _result(found, format, true, notes);
      }
      final atMin = _Candidate(
          encodeImage(current, format, spec.minQuality), current, spec.minQuality);
      if (atMin.bytes.length < best.bytes.length) best = atMin;
      if (!canScale) break;
      // JPEG/WebP size scales roughly with pixel count.
      final factor =
          math.sqrt(target / atMin.bytes.length).clamp(0.3, 0.95).toDouble();
      final nw = (current.width * factor).round();
      final nh = (current.height * factor).round();
      if (nw < 16 || nh < 16) break;
      current = img.copyResize(current,
          width: nw, height: nh, interpolation: img.Interpolation.cubic);
    }
    if (!canScale) {
      // Exact dimensions are required: allow very low quality as a last resort.
      final found = _searchQuality(current, format, target, 5, spec.minQuality - 1);
      if (found != null) {
        notes.add('Quality had to be reduced to ${found.quality} because the '
            'dimensions are fixed. Visible artefacts are likely.');
        return _result(found, format, true, notes);
      }
      final lowest = _Candidate(encodeImage(current, format, 5), current, 5);
      if (lowest.bytes.length < best.bytes.length) best = lowest;
    }
  } else {
    // PNG is lossless: try a 256-colour palette, then smaller dimensions.
    final quantized = img.quantize(image, numberOfColors: 256);
    final q = _Candidate(img.encodePng(quantized, level: 9), quantized, null);
    if (q.bytes.length < best.bytes.length) best = q;
    if (q.bytes.length <= target) {
      notes.add('Reduced to 256 colours to meet the size limit.');
      return _result(q, format, true, notes);
    }
    if (canScale) {
      var cur = image;
      for (var round = 0; round < 8; round++) {
        final factor =
            math.sqrt(target / best.bytes.length).clamp(0.3, 0.9).toDouble();
        final nw = (cur.width * factor).round();
        final nh = (cur.height * factor).round();
        if (nw < 16 || nh < 16) break;
        cur = img.copyResize(cur,
            width: nw, height: nh, interpolation: img.Interpolation.cubic);
        final c = _Candidate(img.encodePng(cur, level: 9), cur, null);
        if (c.bytes.length < best.bytes.length) best = c;
        if (c.bytes.length <= target) {
          notes.add('Dimensions reduced from ${image.width} x ${image.height} '
              'to ${cur.width} x ${cur.height} to meet the size limit.');
          return _result(c, format, true, notes);
        }
      }
    }
  }

  notes.add('Could not reach ${_kb(target)}; the smallest result is '
      '${_kb(best.bytes.length)}.${canScale ? '' : ' Allowing smaller dimensions or a lossy format (JPG/WebP) would help.'}');
  return _result(best, format, false, notes);
}

String _kb(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB'
    : '${(bytes / 1024).toStringAsFixed(1)} KB';

class _Candidate {
  _Candidate(this.bytes, this.image, this.quality);
  final Uint8List bytes;
  final img.Image image;
  final int? quality;
}

ImageResult _result(
        _Candidate c, ImgFormat format, bool met, List<String> notes) =>
    ImageResult(
      bytes: c.bytes,
      width: c.image.width,
      height: c.image.height,
      format: format,
      quality: c.quality,
      targetMet: met,
      notes: notes,
    );

/// Highest quality in [lo]..[hi] whose encoding fits [target], or null.
_Candidate? _searchQuality(
    img.Image image, ImgFormat format, int target, int lo, int hi) {
  if (hi < lo) return null;
  _Candidate? best;
  final low = _Candidate(encodeImage(image, format, lo), image, lo);
  if (low.bytes.length > target) return null;
  best = low;
  var a = lo + 1;
  var b = hi;
  var steps = 0;
  while (a <= b && steps < 7) {
    final mid = (a + b) ~/ 2;
    final bytes = encodeImage(image, format, mid);
    if (bytes.length <= target) {
      best = _Candidate(bytes, image, mid);
      a = mid + 1;
    } else {
      b = mid - 1;
    }
    steps++;
  }
  return best;
}
