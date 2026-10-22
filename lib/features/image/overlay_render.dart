import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'engine/image_engine.dart' as engine;

/// Renders [text] with Flutter's text engine into an RGBA overlay that the
/// image engine composites (pure-Dart bitmap fonts would look poor).
Future<engine.Overlay> renderTextOverlay(
  String text, {
  required Color color,
  double opacity = 0.5,
  double rotationDegrees = 0,
  bool bold = true,
  double centerX = 0.5,
  double centerY = 0.5,
  double widthFraction = 0.5,
  bool tile = false,
  bool shadow = true,
}) async {
  const fontSize = 160.0;
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'Inter',
        fontSize: fontSize,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        color: color.withValues(alpha: opacity),
        shadows: shadow
            ? [
                Shadow(
                  color: Colors.black.withValues(alpha: opacity * 0.35),
                  blurRadius: 6,
                  offset: const Offset(2, 2),
                ),
              ]
            : null,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final rad = rotationDegrees * math.pi / 180;
  final w = tp.width, h = tp.height;
  final cos = math.cos(rad).abs();
  final sin = math.sin(rad).abs();
  final bw = (w * cos + h * sin).ceil() + 8;
  final bh = (w * sin + h * cos).ceil() + 8;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.translate(bw / 2, bh / 2);
  canvas.rotate(rad);
  tp.paint(canvas, Offset(-w / 2, -h / 2));
  final picture = recorder.endRecording();
  final image = await picture.toImage(bw, bh);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  image.dispose();
  picture.dispose();
  tp.dispose();
  return engine.Overlay(
    rgba: data!.buffer.asUint8List(),
    width: bw,
    height: bh,
    centerX: centerX,
    centerY: centerY,
    widthFraction: widthFraction,
    tile: tile,
  );
}
