import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'image_format.dart';

/// A metadata block found in an image file.
class MetadataBlock {
  const MetadataBlock(this.kind, this.bytes, {this.sensitive = false});

  /// e.g. "EXIF", "XMP", "IPTC", "ICC profile", "Comment", "Text".
  final String kind;
  final int bytes;

  /// Likely to contain personal data (camera, location, author, time).
  final bool sensitive;
}

class MetadataReport {
  MetadataReport({
    required this.format,
    required this.blocks,
    required this.tags,
    required this.hasGps,
    required this.orientation,
  });

  final ImgFormat? format;
  final List<MetadataBlock> blocks;

  /// Human-readable EXIF tags (name -> value), most relevant first.
  final Map<String, String> tags;
  final bool hasGps;
  final int orientation;

  bool get hasRemovable => blocks.any((b) => b.kind != 'ICC profile');
}

const _interestingTags = <String>[
  'Make',
  'Model',
  'DateTime',
  'DateTimeOriginal',
  'Software',
  'Artist',
  'Copyright',
  'ImageDescription',
  'LensModel',
  'ExposureTime',
  'FNumber',
  'ISOSpeedRatings',
  'FocalLength',
  'GPSLatitude',
  'GPSLongitude',
  'GPSAltitude',
];

const _gpsTagNames = <int, String>{
  1: 'GPSLatitudeRef',
  2: 'GPSLatitude',
  3: 'GPSLongitudeRef',
  4: 'GPSLongitude',
  5: 'GPSAltitudeRef',
  6: 'GPSAltitude',
  7: 'GPSTimeStamp',
  29: 'GPSDateStamp',
};

/// Lists metadata without decoding pixels.
MetadataReport inspectMetadata(Uint8List bytes) {
  final format = ImgFormat.sniff(bytes);
  final blocks = <MetadataBlock>[];
  switch (format) {
    case ImgFormat.jpeg:
      for (final s in _jpegSegments(bytes)) {
        final kind = _jpegKind(bytes, s);
        if (kind != null) {
          blocks.add(MetadataBlock(kind, s.length, sensitive: kind != 'ICC profile'));
        }
      }
    case ImgFormat.png:
      for (final c in _pngChunks(bytes)) {
        final kind = _pngKind(c.type);
        if (kind != null) {
          blocks.add(MetadataBlock(kind, c.length + 12, sensitive: kind != 'ICC profile'));
        }
      }
    case ImgFormat.webp:
      for (final c in _riffChunks(bytes)) {
        final kind = switch (c.type) {
          'EXIF' => 'EXIF',
          'XMP ' => 'XMP',
          'ICCP' => 'ICC profile',
          _ => null,
        };
        if (kind != null) {
          blocks.add(MetadataBlock(kind, c.length + 8, sensitive: kind != 'ICC profile'));
        }
      }
    case null:
      break;
  }

  final tags = <String, String>{};
  var hasGps = false;
  var orientation = 1;
  img.ExifData? exif;
  if (format == ImgFormat.jpeg) {
    exif = img.decodeJpgExif(bytes);
  } else if (blocks.any((b) => b.kind == 'EXIF')) {
    exif = img.decodeImage(bytes)?.exif;
  }
  if (exif != null) {
    hasGps = !exif.gpsIfd.isEmpty;
    if (exif.imageIfd.hasOrientation) {
      orientation = exif.imageIfd.orientation ?? 1;
    }
    final all = <String, String>{};
    void collect(img.IfdDirectory dir) {
      for (final entry in dir.data.entries) {
        final name = img.exifImageTags[entry.key]?.name ?? '0x${entry.key.toRadixString(16)}';
        final value = entry.value.toString();
        if (value.length <= 80) all[name] = value;
      }
    }

    collect(exif.imageIfd);
    final exifSub = exif.imageIfd.sub['exif'];
    if (!exifSub.isEmpty) collect(exifSub);
    for (final entry in exif.gpsIfd.data.entries) {
      all[_gpsTagNames[entry.key] ?? 'GPS 0x${entry.key.toRadixString(16)}'] = entry.value.toString();
    }
    for (final k in _interestingTags) {
      if (all.containsKey(k)) tags[k] = all.remove(k)!;
    }
    tags.addAll(all);
  }
  return MetadataReport(format: format, blocks: blocks, tags: tags, hasGps: hasGps, orientation: orientation);
}

/// Removes metadata without re-encoding the pixels. When the EXIF
/// orientation is not "normal", a minimal EXIF block containing only the
/// orientation is kept so the photo still displays the right way up.
Uint8List stripMetadataLossless(Uint8List bytes, {bool keepColorProfile = true}) {
  final format = ImgFormat.sniff(bytes);
  switch (format) {
    case ImgFormat.jpeg:
      return _stripJpeg(bytes, keepColorProfile);
    case ImgFormat.png:
      return _stripPng(bytes, keepColorProfile);
    case ImgFormat.webp:
      return _stripWebp(bytes, keepColorProfile);
    case null:
      throw ArgumentError('Unsupported image format');
  }
}

// ---------------- JPEG ----------------

class _Seg {
  _Seg(this.marker, this.start, this.length);
  final int marker;

  /// Offset of the 0xFF marker byte.
  final int start;

  /// Total bytes including marker and length field.
  final int length;
}

/// Segments before the start-of-scan marker.
List<_Seg> _jpegSegments(Uint8List b) {
  final out = <_Seg>[];
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) break;
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) break; // SOS / EOI
    if (marker >= 0xD0 && marker <= 0xD7) {
      i += 2;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2 || i + 2 + len > b.length) break;
    out.add(_Seg(marker, i, len + 2));
    i += len + 2;
  }
  return out;
}

bool _startsWith(Uint8List b, int offset, String ascii) {
  if (offset + ascii.length > b.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (b[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

String? _jpegKind(Uint8List b, _Seg s) {
  final payload = s.start + 4;
  switch (s.marker) {
    case 0xE1:
      if (_startsWith(b, payload, 'Exif\u0000')) return 'EXIF';
      if (_startsWith(b, payload, 'http://ns.adobe.com/')) return 'XMP';
      return 'APP1';
    case 0xE2:
      if (_startsWith(b, payload, 'ICC_PROFILE')) return 'ICC profile';
      return 'APP2';
    case 0xED:
      return 'IPTC';
    case 0xFE:
      return 'Comment';
    default:
      if (s.marker >= 0xE3 && s.marker <= 0xEF && s.marker != 0xEE) {
        return 'APP${s.marker - 0xE0}';
      }
      return null; // APP0 (JFIF), APP14 (Adobe colour transform), tables...
  }
}

Uint8List _stripJpeg(Uint8List b, bool keepIcc) {
  final orientation = img.decodeJpgExif(b)?.imageIfd.orientation ?? 1;
  final segments = _jpegSegments(b);
  final out = BytesBuilder(copy: false);
  out.add(b.sublist(0, 2)); // SOI
  var cursor = 2;
  var insertedExif = false;
  for (final s in segments) {
    final kind = _jpegKind(b, s);
    final drop = kind != null && !(keepIcc && kind == 'ICC profile');
    if (s.start > cursor) out.add(b.sublist(cursor, s.start));
    if (!drop) {
      out.add(b.sublist(s.start, s.start + s.length));
      if (!insertedExif && s.marker == 0xE0 && orientation != 1) {
        out.add(_minimalExif(orientation));
        insertedExif = true;
      }
    }
    cursor = s.start + s.length;
  }
  if (!insertedExif && orientation != 1) {
    // No APP0: put the orientation block right after SOI.
    final rest = b.sublist(cursor);
    final head = out.takeBytes();
    final rebuilt = BytesBuilder(copy: false)
      ..add(head.sublist(0, 2))
      ..add(_minimalExif(orientation))
      ..add(head.sublist(2))
      ..add(rest);
    return rebuilt.takeBytes();
  }
  out.add(b.sublist(cursor));
  return out.takeBytes();
}

/// APP1 segment with a TIFF header and a single Orientation entry.
Uint8List _minimalExif(int orientation) {
  final d = BytesBuilder();
  d.add([0xFF, 0xE1]);
  const payloadLen = 6 + 8 + 2 + 12 + 4; // Exif\0\0 + TIFF + count + entry + next
  final segLen = payloadLen + 2;
  d.add([segLen >> 8, segLen & 0xFF]);
  d.add('Exif'.codeUnits);
  d.add([0, 0]);
  d.add([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]); // "II*\0", IFD0 at 8
  d.add([0x01, 0x00]); // one entry
  d.add([0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00]); // tag 0x0112 SHORT x1
  d.add([orientation & 0xFF, 0x00, 0x00, 0x00]);
  d.add([0, 0, 0, 0]); // no next IFD
  return d.toBytes();
}

// ---------------- PNG ----------------

class _Chunk {
  _Chunk(this.type, this.start, this.length);
  final String type;

  /// Offset of the length field.
  final int start;

  /// Data length (excluding length, type and CRC).
  final int length;
}

List<_Chunk> _pngChunks(Uint8List b) {
  final out = <_Chunk>[];
  var i = 8;
  while (i + 12 <= b.length) {
    final len = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
    if (len < 0 || i + 12 + len > b.length) break;
    final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
    out.add(_Chunk(type, i, len));
    i += 12 + len;
    if (type == 'IEND') break;
  }
  return out;
}

String? _pngKind(String type) => switch (type) {
  'tEXt' || 'zTXt' || 'iTXt' => 'Text',
  'eXIf' => 'EXIF',
  'tIME' => 'Timestamp',
  'iCCP' => 'ICC profile',
  _ => null,
};

Uint8List _stripPng(Uint8List b, bool keepIcc) {
  final out = BytesBuilder(copy: false)..add(b.sublist(0, 8));
  for (final c in _pngChunks(b)) {
    final kind = _pngKind(c.type);
    final drop = kind != null && !(keepIcc && kind == 'ICC profile');
    if (!drop) out.add(b.sublist(c.start, c.start + 12 + c.length));
  }
  return out.takeBytes();
}

// ---------------- WebP ----------------

List<_Chunk> _riffChunks(Uint8List b) {
  final out = <_Chunk>[];
  var i = 12;
  while (i + 8 <= b.length) {
    final type = String.fromCharCodes(b.sublist(i, i + 4));
    final len = b[i + 4] | (b[i + 5] << 8) | (b[i + 6] << 16) | (b[i + 7] << 24);
    if (len < 0 || i + 8 + len > b.length) break;
    out.add(_Chunk(type, i, len));
    i += 8 + len + (len & 1);
  }
  return out;
}

Uint8List _stripWebp(Uint8List b, bool keepIcc) {
  final body = BytesBuilder(copy: false);
  for (final c in _riffChunks(b)) {
    final drop = c.type == 'EXIF' || c.type == 'XMP ' || (!keepIcc && c.type == 'ICCP');
    if (drop) continue;
    final end = c.start + 8 + c.length + (c.length & 1);
    final chunk = Uint8List.fromList(b.sublist(c.start, end.clamp(0, b.length)));
    if (c.type == 'VP8X' && chunk.length >= 9) {
      // Clear the EXIF (0x08) and XMP (0x04) flags; ICC (0x20) if removed.
      var flags = chunk[8] & ~0x0C;
      if (!keepIcc) flags &= ~0x20;
      chunk[8] = flags;
    }
    body.add(chunk);
  }
  final data = body.takeBytes();
  final size = data.length + 4;
  return (BytesBuilder(copy: false)
        ..add('RIFF'.codeUnits)
        ..add([size & 0xFF, (size >> 8) & 0xFF, (size >> 16) & 0xFF, (size >> 24) & 0xFF])
        ..add('WEBP'.codeUnits)
        ..add(data))
      .takeBytes();
}
