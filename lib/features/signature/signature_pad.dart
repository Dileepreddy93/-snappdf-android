import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Strokes drawn on the pad, in pad-local logical pixels.
class SignatureStrokes extends ChangeNotifier {
  final List<List<Offset>> _strokes = [];
  final List<List<Offset>> _redo = [];

  List<List<Offset>> get strokes => _strokes;
  bool get isEmpty => _strokes.every((s) => s.isEmpty);
  bool get canUndo => _strokes.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void begin(Offset p) {
    _strokes.add([p]);
    _redo.clear();
    notifyListeners();
  }

  void extend(Offset p) {
    if (_strokes.isEmpty) return;
    final s = _strokes.last;
    if (s.isNotEmpty && (s.last - p).distanceSquared < 1.0) return;
    s.add(p);
    notifyListeners();
  }

  void undo() {
    if (_strokes.isEmpty) return;
    _redo.add(_strokes.removeLast());
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _strokes.add(_redo.removeLast());
    notifyListeners();
  }

  void clear() {
    _strokes.clear();
    _redo.clear();
    notifyListeners();
  }

  Rect? get bounds {
    double? l, t, r, b;
    for (final s in _strokes) {
      for (final p in s) {
        l = l == null ? p.dx : math.min(l, p.dx);
        t = t == null ? p.dy : math.min(t, p.dy);
        r = r == null ? p.dx : math.max(r, p.dx);
        b = b == null ? p.dy : math.max(b, p.dy);
      }
    }
    if (l == null) return null;
    return Rect.fromLTRB(l, t!, r!, b!);
  }

  /// Renders strokes cropped to their bounds (plus padding) as a transparent
  /// PNG. [scale] multiplies resolution (e.g. 3 for print-quality output).
  Future<Uint8List?> toPng({required Color color, required double width, double scale = 3, double padding = 12}) async {
    final b = bounds;
    if (b == null) return null;
    final area = b.inflate(width / 2 + padding);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    canvas.translate(-area.left, -area.top);
    paintStrokes(canvas, _strokes, color, width);
    final picture = recorder.endRecording();
    final image = await picture.toImage((area.width * scale).ceil(), (area.height * scale).ceil());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return data?.buffer.asUint8List();
  }
}

/// Smooth strokes: quadratic curves through midpoints.
void paintStrokes(Canvas canvas, List<List<Offset>> strokes, Color color, double width) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true;
  for (final s in strokes) {
    if (s.isEmpty) continue;
    if (s.length == 1) {
      canvas.drawCircle(s.first, width / 2, Paint()..color = color);
      continue;
    }
    final path = Path()..moveTo(s.first.dx, s.first.dy);
    for (var i = 1; i < s.length - 1; i++) {
      final mid = Offset((s[i].dx + s[i + 1].dx) / 2, (s[i].dy + s[i + 1].dy) / 2);
      path.quadraticBezierTo(s[i].dx, s[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(s.last.dx, s.last.dy);
    canvas.drawPath(path, paint);
  }
}

class SignaturePad extends StatelessWidget {
  const SignaturePad({super.key, required this.strokes, required this.color, required this.width, this.height = 220});
  final SignatureStrokes strokes;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Signature drawing area. Draw your signature with your finger.',
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: s.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: GestureDetector(
          onPanStart: (d) => strokes.begin(d.localPosition),
          onPanUpdate: (d) => strokes.extend(d.localPosition),
          child: AnimatedBuilder(
            animation: strokes,
            builder: (context, _) => CustomPaint(
              painter: _PadPainter(strokes.strokes, color, width),
              child: strokes.isEmpty
                  ? Center(
                      child: Text(
                        'Sign here',
                        style: Theme.of(context).textTheme.titleMedium!.copyWith(color: Colors.black26),
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, this.color, this.width);
  final List<List<Offset>> strokes;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final guide = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1;
    canvas.drawLine(Offset(24, size.height * 0.72), Offset(size.width - 24, size.height * 0.72), guide);
    paintStrokes(canvas, strokes, color, width);
  }

  @override
  bool shouldRepaint(covariant _PadPainter old) => true;
}
