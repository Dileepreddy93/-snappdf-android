import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Interactive crop rectangle over an image. [rect] is in image pixels.
/// When [aspect] (width / height) is set the rectangle keeps that ratio.
class CropBox extends StatefulWidget {
  const CropBox({
    super.key,
    required this.image,
    required this.imageSize,
    required this.rect,
    required this.onChanged,
    this.aspect,
    this.guide,
  });

  final ImageProvider image;
  final Size imageSize;
  final Rect rect;
  final double? aspect;
  final ValueChanged<Rect> onChanged;

  /// Optional painter for guides inside the crop (e.g. passport face oval).
  final CustomPainter Function(Rect cropOnScreen)? guide;

  @override
  State<CropBox> createState() => _CropBoxState();
}

enum _Handle { move, tl, tr, bl, br }

class _CropBoxState extends State<CropBox> {
  _Handle? _active;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, c) {
        final scale = math.min(c.maxWidth / widget.imageSize.width, c.maxHeight / widget.imageSize.height);
        final dw = widget.imageSize.width * scale;
        final dh = widget.imageSize.height * scale;
        final r = Rect.fromLTRB(
          widget.rect.left * scale,
          widget.rect.top * scale,
          widget.rect.right * scale,
          widget.rect.bottom * scale,
        );

        _Handle? hit(Offset p) {
          const slop = 28.0;
          if ((p - r.topLeft).distance < slop) return _Handle.tl;
          if ((p - r.topRight).distance < slop) return _Handle.tr;
          if ((p - r.bottomLeft).distance < slop) return _Handle.bl;
          if ((p - r.bottomRight).distance < slop) return _Handle.br;
          if (r.contains(p)) return _Handle.move;
          return null;
        }

        void update(Offset delta) {
          final d = delta / scale;
          final img = Offset.zero & widget.imageSize;
          var nr = widget.rect;
          const minSide = 16.0;
          switch (_active) {
            case _Handle.move:
              var shifted = nr.shift(d);
              final dx = shifted.left < 0
                  ? -shifted.left
                  : (shifted.right > img.right ? img.right - shifted.right : 0.0);
              final dy = shifted.top < 0
                  ? -shifted.top
                  : (shifted.bottom > img.bottom ? img.bottom - shifted.bottom : 0.0);
              shifted = shifted.shift(Offset(dx, dy));
              nr = shifted;
            case _Handle.tl || _Handle.tr || _Handle.bl || _Handle.br:
              var l = nr.left, t = nr.top, rr = nr.right, b = nr.bottom;
              if (_active == _Handle.tl || _active == _Handle.bl) l = (l + d.dx).clamp(0, rr - minSide);
              if (_active == _Handle.tr || _active == _Handle.br) rr = (rr + d.dx).clamp(l + minSide, img.right);
              if (_active == _Handle.tl || _active == _Handle.tr) t = (t + d.dy).clamp(0, b - minSide);
              if (_active == _Handle.bl || _active == _Handle.br) b = (b + d.dy).clamp(t + minSide, img.bottom);
              if (widget.aspect != null) {
                // Width drives height; anchor at the opposite corner.
                final w = rr - l;
                var h = w / widget.aspect!;
                if (_active == _Handle.tl || _active == _Handle.tr) {
                  t = b - h;
                  if (t < 0) {
                    t = 0;
                    h = b;
                    final nw = h * widget.aspect!;
                    if (_active == _Handle.tl) {
                      l = rr - nw;
                    } else {
                      rr = l + nw;
                    }
                  }
                } else {
                  b = t + h;
                  if (b > img.bottom) {
                    b = img.bottom;
                    h = b - t;
                    final nw = h * widget.aspect!;
                    if (_active == _Handle.bl) {
                      l = rr - nw;
                    } else {
                      rr = l + nw;
                    }
                  }
                }
              }
              nr = Rect.fromLTRB(l, t, rr, b);
            case null:
              return;
          }
          widget.onChanged(nr);
        }

        return Center(
          child: SizedBox(
            width: dw,
            height: dh,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (d) => _active = hit(d.localPosition),
              onPanUpdate: (d) => update(d.delta),
              onPanEnd: (_) => _active = null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image(image: widget.image, fit: BoxFit.fill, gaplessPlayback: true),
                  CustomPaint(painter: _CropPainter(r, s.primary)),
                  if (widget.guide != null) CustomPaint(painter: widget.guide!(r)),
                  Semantics(label: 'Crop area. Drag to move, drag corners to resize.', child: const SizedBox.expand()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.r, this.color);
  final Rect r;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.5);
    final full = Offset.zero & size;
    canvas.drawPath(Path.combine(PathOperation.difference, Path()..addRect(full), Path()..addRect(r)), shade);
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(r, line);
    final thirds = Paint()
      ..color = Colors.white54
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(r.left + r.width * i / 3, r.top), Offset(r.left + r.width * i / 3, r.bottom), thirds);
      canvas.drawLine(Offset(r.left, r.top + r.height * i / 3), Offset(r.right, r.top + r.height * i / 3), thirds);
    }
    final handle = Paint()..color = color;
    for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(c, 9, Paint()..color = Colors.white);
      canvas.drawCircle(c, 6, handle);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.r != r;
}

/// Largest centred rectangle of [aspect] inside [size].
Rect centeredAspectRect(Size size, double? aspect, {double fill = 1}) {
  if (aspect == null) return Offset.zero & size;
  var w = size.width * fill;
  var h = w / aspect;
  if (h > size.height * fill) {
    h = size.height * fill;
    w = h * aspect;
  }
  return Rect.fromCenter(center: size.center(Offset.zero), width: w, height: h);
}
