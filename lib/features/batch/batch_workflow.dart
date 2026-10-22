import '../../core/files/file_kind.dart';
import '../image/engine/image_engine.dart';
import '../image/engine/image_format.dart';

/// A reusable image workflow: resize -> compress -> convert -> rename.
class BatchPreset {
  const BatchPreset({
    required this.name,
    this.resize,
    this.targetBytes,
    this.quality = 85,
    this.format,
    this.renamePattern = '{name}',
    this.stripMetadata = true,
  });

  final String name;
  final ResizeSpec? resize;
  final int? targetBytes;
  final int quality;
  final ImgFormat? format;

  /// Tokens: {name} original name, {n} running number, {date} yyyy-mm-dd.
  final String renamePattern;

  /// Re-encoding always drops EXIF/GPS; kept as an explicit, visible choice.
  final bool stripMetadata;

  ImageSpec toSpec() => ImageSpec(format: format, quality: quality, targetBytes: targetBytes, resize: resize);

  Map<String, Object?> toJson() => {
    'name': name,
    'resize': resize?.toJson(),
    'targetBytes': targetBytes,
    'quality': quality,
    'format': format?.name,
    'renamePattern': renamePattern,
    'stripMetadata': stripMetadata,
  };

  factory BatchPreset.fromJson(Map<String, Object?> j) => BatchPreset(
    name: j['name'] as String,
    resize: j['resize'] == null ? null : ResizeSpec.fromJson((j['resize'] as Map).cast<String, Object?>()),
    targetBytes: j['targetBytes'] as int?,
    quality: j['quality'] as int? ?? 85,
    format: j['format'] == null ? null : ImgFormat.values.byName(j['format'] as String),
    renamePattern: j['renamePattern'] as String? ?? '{name}',
    stripMetadata: j['stripMetadata'] as bool? ?? true,
  );
}

/// Built-in starting points.
const builtInPresets = [
  BatchPreset(
    name: 'Email-friendly (1600 px, 300 KB)',
    resize: ResizeSpec(width: 1600, height: 1600),
    targetBytes: 300 * 1024,
    format: ImgFormat.jpeg,
  ),
  BatchPreset(name: 'Form upload (100 KB JPG)', targetBytes: 100 * 1024, format: ImgFormat.jpeg),
  BatchPreset(
    name: 'Web (1200 px WebP)',
    resize: ResizeSpec(width: 1200, height: 1200),
    quality: 80,
    format: ImgFormat.webp,
  ),
];

/// Applies a rename pattern; result has [extension] and is unique in [taken].
String applyRenamePattern(
  String pattern,
  String originalName,
  int index,
  String extension,
  DateTime date,
  Set<String> taken,
) {
  final base = originalName.contains('.') ? originalName.substring(0, originalName.lastIndexOf('.')) : originalName;
  String two(int v) => v.toString().padLeft(2, '0');
  var stem = (pattern.trim().isEmpty ? '{name}' : pattern)
      .replaceAll('{name}', base)
      .replaceAll('{n}', '${index + 1}')
      .replaceAll('{date}', '${date.year}-${two(date.month)}-${two(date.day)}');
  stem = sanitizeFileName(stem, fallback: 'image_${index + 1}');
  final name = uniqueName('$stem.$extension', taken);
  taken.add(name.toLowerCase());
  return name;
}
