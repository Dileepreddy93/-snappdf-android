import 'package:path/path.dart' as p;

enum FileKind {
  pdf('PDF'),
  image('Image'),
  text('Text'),
  other('File');

  const FileKind(this.label);
  final String label;

  static FileKind ofName(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.pdf':
        return FileKind.pdf;
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.webp':
      case '.gif':
      case '.bmp':
      case '.heic':
      case '.heif':
      case '.tif':
      case '.tiff':
        return FileKind.image;
      case '.txt':
      case '.md':
      case '.csv':
        return FileKind.text;
    }
    return FileKind.other;
  }
}

String mimeForName(String name) {
  switch (p.extension(name).toLowerCase()) {
    case '.pdf':
      return 'application/pdf';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.png':
      return 'image/png';
    case '.webp':
      return 'image/webp';
    case '.gif':
      return 'image/gif';
    case '.txt':
      return 'text/plain';
    case '.zip':
      return 'application/zip';
  }
  return 'application/octet-stream';
}

/// "1.2 MB", "340 KB", "812 B".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return '${kb < 10 ? kb.toStringAsFixed(1) : kb.round()} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 2 : 1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Removes characters not allowed in file names and trims length.
String sanitizeFileName(String name, {String fallback = 'file'}) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim().replaceAll(RegExp(r'^\.+|\.+$'), '');
  if (cleaned.isEmpty) return fallback;
  if (cleaned.length <= 120) return cleaned;
  final ext = p.extension(cleaned);
  return cleaned.substring(0, 120 - ext.length) + ext;
}

/// "report.pdf" + "compressed" -> "report_compressed.pdf".
String derivedName(String original, String suffix, {String? extension}) {
  final base = p.basenameWithoutExtension(original);
  final ext = extension ?? p.extension(original).replaceFirst('.', '');
  final stem = suffix.isEmpty ? base : '${base}_$suffix';
  return sanitizeFileName(ext.isEmpty ? stem : '$stem.$ext');
}

/// Returns [name] or "name (2).ext", "name (3).ext"... not present in [taken].
String uniqueName(String name, Iterable<String> taken) {
  final set = taken.map((e) => e.toLowerCase()).toSet();
  if (!set.contains(name.toLowerCase())) return name;
  final ext = p.extension(name);
  var base = p.basenameWithoutExtension(name);
  final m = RegExp(r'^(.*) \((\d+)\)$').firstMatch(base);
  var n = 2;
  if (m != null) {
    base = m.group(1)!;
    n = int.parse(m.group(2)!) + 1;
  }
  while (true) {
    final candidate = '$base ($n)$ext';
    if (!set.contains(candidate.toLowerCase())) return candidate;
    n++;
  }
}
