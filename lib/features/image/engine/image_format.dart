import 'dart:typed_data';

/// Raster formats SnapPDF can read and write.
enum ImgFormat {
  jpeg('JPG', 'jpg', 'image/jpeg', lossy: true, alpha: false),
  png('PNG', 'png', 'image/png', lossy: false, alpha: true),
  webp('WebP', 'webp', 'image/webp', lossy: true, alpha: true);

  const ImgFormat(this.label, this.extension, this.mime, {required this.lossy, required this.alpha});

  final String label;
  final String extension;
  final String mime;

  /// Supports a quality setting (and therefore target-size search).
  final bool lossy;

  /// Can store transparency.
  final bool alpha;

  static ImgFormat? fromExtension(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
      case 'jfif':
        return ImgFormat.jpeg;
      case 'png':
        return ImgFormat.png;
      case 'webp':
        return ImgFormat.webp;
    }
    return null;
  }

  /// Identifies the format from file signature bytes (not the extension).
  static ImgFormat? sniff(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return ImgFormat.jpeg;
    }
    if (b.length >= 8 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47 &&
        b[4] == 0x0D &&
        b[5] == 0x0A &&
        b[6] == 0x1A &&
        b[7] == 0x0A) {
      return ImgFormat.png;
    }
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return ImgFormat.webp;
    }
    return null;
  }
}

/// Other formats we can decode (and convert from), but not write.
bool isDecodableImagePath(String path) {
  final ext = path.split('.').last.toLowerCase();
  return const {'jpg', 'jpeg', 'jfif', 'png', 'webp', 'bmp', 'gif', 'tif', 'tiff'}.contains(ext);
}
