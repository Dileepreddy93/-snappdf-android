import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/files/workspace.dart';
import 'engine/image_engine.dart';
import 'engine/image_format.dart';

/// Re-encodes [path] as PNG (if it has transparency) or JPEG, limited to
/// [maxSide] pixels, so the PDF engine can embed it. Returns the new path and
/// pixel size.
Future<({String path, int width, int height})> prepareImageForPdf(
  String path,
  Workspace ws, {
  int maxSide = 2000,
}) async {
  final bytes = await File(path).readAsBytes();
  final probe = await Future(() => probeImage(bytes));
  final format = probe.hasAlpha ? ImgFormat.png : ImgFormat.jpeg;
  final result = await processImage(
    bytes,
    ImageSpec(
      format: format,
      quality: 90,
      resize: ResizeSpec(width: maxSide, height: maxSide),
    ),
  );
  final dir = await ws.newWorkDir();
  final out = p.join(dir.path, 'image.${format.extension}');
  await File(out).writeAsBytes(result.bytes, flush: true);
  return (path: out, width: result.width, height: result.height);
}
