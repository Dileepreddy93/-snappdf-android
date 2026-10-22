import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import 'crop_box.dart';
import 'engine/image_engine.dart';
import 'engine/image_format.dart';
import 'image_tools.dart';

/// Upright source image plus a small proxy for fast previews.
class LoadedImage {
  LoadedImage(this.bytes, this.width, this.height, this.proxy, this.proxyScale, this.hasAlpha);
  final Uint8List bytes;
  final int width;
  final int height;

  /// PNG of the upright image limited to ~1200 px.
  final Uint8List proxy;
  final double proxyScale;
  final bool hasAlpha;

  static Future<LoadedImage> load(String path) async {
    final bytes = await File(path).readAsBytes();
    return Isolate.run(() {
      final up = decodeUpright(bytes);
      final scale = math.min(1.0, 1200 / math.max(up.width, up.height));
      final small = scale < 1
          ? img.copyResize(
              up,
              width: (up.width * scale).round(),
              height: (up.height * scale).round(),
              interpolation: img.Interpolation.average,
            )
          : up;
      final alpha = up.hasAlpha;
      return LoadedImage(bytes, up.width, up.height, img.encodePng(small, level: 1), scale, alpha);
    });
  }
}

class PhotoEditorScreen extends ConsumerStatefulWidget {
  const PhotoEditorScreen({super.key, this.initial = const [], this.backgroundMode = false});
  final List<InputFile> initial;

  /// Background replacement tool instead of the general editor.
  final bool backgroundMode;

  @override
  ConsumerState<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends ConsumerState<PhotoEditorScreen> {
  InputFile? _input;
  LoadedImage? _img;
  String? _loadError;

  // Edits
  Rect? _crop;
  double? _aspect;
  int _rotate = 0;
  bool _flipH = false, _flipV = false;
  double _brightness = 0, _contrast = 0, _saturation = 0, _sharpness = 0;
  ImgFormat? _format;
  late int _quality = ref.read(settingsProvider).defaultJpegQuality;
  int _tab = 0;

  // Background
  Uint8List? _mask;
  double? _maskCoverage;
  int? _bgColor; // null = transparent
  bool _masking = false;

  Uint8List? _preview;
  Timer? _debounce;
  bool _comparing = false;
  int _previewSeq = 0;

  static const _aspects = <String, double?>{
    'Free': null,
    '1:1': 1,
    '4:3': 4 / 3,
    '3:4': 3 / 4,
    '16:9': 16 / 9,
    '9:16': 9 / 16,
  };

  @override
  void initState() {
    super.initState();
    final f = widget.initial.where((x) => x.kind == FileKind.image).firstOrNull;
    if (f != null) WidgetsBinding.instance.addPostFrameCallback((_) => _open(f));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _open(InputFile f) async {
    setState(() {
      _input = f;
      _img = null;
      _loadError = null;
      _mask = null;
    });
    try {
      final loaded = await LoadedImage.load(f.path);
      if (!mounted) return;
      setState(() {
        _img = loaded;
        _crop = Rect.fromLTWH(0, 0, loaded.width.toDouble(), loaded.height.toDouble());
        _format = null;
      });
      if (widget.backgroundMode) await _computeMask();
      _schedulePreview();
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  Future<void> _computeMask() async {
    setState(() => _masking = true);
    try {
      final ws = ref.read(workspaceProvider);
      final out = await ws.newWorkFile('mask.png');
      final r = await ref.read(nativeApiProvider).personMask(_input!.path, out);
      final bytes = await File(r.path).readAsBytes();
      if (!mounted) return;
      setState(() {
        _mask = bytes;
        _maskCoverage = r.coverage;
        _format ??= _bgColor == null ? ImgFormat.png : ImgFormat.jpeg;
      });
    } on NativeError catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    } finally {
      if (mounted) setState(() => _masking = false);
    }
  }

  bool get _fullCrop =>
      _crop == null ||
      (_crop!.left <= 0.5 &&
          _crop!.top <= 0.5 &&
          (_crop!.width - _img!.width).abs() < 1 &&
          (_crop!.height - _img!.height).abs() < 1);

  ImageSpec _spec({required bool proxy}) {
    final s = proxy ? _img!.proxyScale : 1.0;
    final c = _crop;
    return ImageSpec(
      format: proxy ? ImgFormat.png : (_format ?? (widget.backgroundMode && _bgColor == null ? ImgFormat.png : null)),
      quality: _quality,
      crop: c == null || _fullCrop
          ? null
          : CropRect((c.left * s).round(), (c.top * s).round(), (c.width * s).round(), (c.height * s).round()),
      rotate: _rotate,
      flipH: _flipH,
      flipV: _flipV,
      adjust: Adjustments(brightness: _brightness, contrast: _contrast, saturation: _saturation, sharpness: _sharpness),
      mask: widget.backgroundMode ? _mask : null,
      maskBackground: _bgColor,
      background: _bgColor ?? 0xFFFFFFFF,
    );
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () async {
      final img = _img;
      if (img == null) return;
      final seq = ++_previewSeq;
      try {
        final r = await processImage(img.proxy, _spec(proxy: true));
        if (mounted && seq == _previewSeq) setState(() => _preview = r.bytes);
      } catch (_) {}
    });
  }

  void _changed(VoidCallback f) {
    setState(f);
    _schedulePreview();
  }

  void _setAspect(double? a) {
    final img = _img!;
    final size = Size(img.width.toDouble(), img.height.toDouble());
    _changed(() {
      _aspect = a;
      _crop = centeredAspectRect(size, a);
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.backgroundMode ? 'Change background' : 'Photo editor';
    return ToolScaffold(
      title: title,
      about: widget.backgroundMode
          ? 'Separates a person from the background on your device and replaces the background with a colour or '
                'makes it transparent (PNG). Works best for portraits with good contrast; hair edges may be imperfect. '
                'Other subjects (products, objects) are not reliably detected.'
          : 'Crop, rotate, flip and adjust brightness, contrast, saturation and sharpness. Press and hold the preview '
                'to compare with the original. The original photo is not changed.',
      actionLabel: 'Save photo',
      actionIcon: Icons.save_alt_rounded,
      canRun: () {
        if (_img == null) return 'Choose a photo';
        if (widget.backgroundMode && _mask == null) {
          return _masking ? 'Detecting the person…' : 'Background detection failed';
        }
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InputsCard(
            inputs: [?_input],
            accept: Accept.image,
            emptyLabel: widget.backgroundMode ? 'Choose a portrait photo' : 'Choose a photo',
            onChanged: (l) {
              if (l.isEmpty) {
                setState(() {
                  _input = null;
                  _img = null;
                });
              } else {
                _open(l.first);
              }
            },
          ),
          if (_loadError != null) ...[
            const SizedBox(height: Gaps.l),
            MessageBanner(kind: BannerKind.error, message: _loadError!),
          ],
          if (_input != null && _img == null && _loadError == null)
            const Padding(
              padding: EdgeInsets.all(Gaps.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_img != null) ...[
            const SizedBox(height: Gaps.l),
            if (!widget.backgroundMode)
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Crop & rotate'), icon: Icon(Icons.crop_rotate_rounded)),
                  ButtonSegment(value: 1, label: Text('Adjust'), icon: Icon(Icons.tune_rounded)),
                ],
                selected: {_tab},
                onSelectionChanged: (v) => setState(() => _tab = v.first),
              ),
            const SizedBox(height: Gaps.l),
            SizedBox(height: 340, child: _tab == 0 && !widget.backgroundMode ? _cropView() : _previewView()),
            const SizedBox(height: Gaps.l),
            if (widget.backgroundMode)
              ..._backgroundOptions()
            else if (_tab == 0)
              ..._cropOptions()
            else
              ..._adjustOptions(),
            const SizedBox(height: Gaps.l),
            OptionGroup(
              title: 'Save as',
              children: [
                FormatPicker(value: _format, onChanged: (v) => setState(() => _format = v)),
                if ((_format ?? ImgFormat.sniff(_img!.bytes) ?? ImgFormat.jpeg).lossy)
                  LabeledSlider(
                    label: 'Quality',
                    value: _quality.toDouble(),
                    min: 10,
                    max: 100,
                    divisions: 18,
                    onChanged: (v) => setState(() => _quality = v.round()),
                  ),
              ],
            ),
          ],
        ],
      ),
      run: (context, job) async {
        job.message.value = 'Rendering full resolution…';
        final r = await processImage(_img!.bytes, _spec(proxy: false));
        final ws = ref.read(workspaceProvider);
        final name = derivedName(
          _input!.name,
          widget.backgroundMode ? 'background' : 'edited',
          extension: r.format.extension,
        );
        final out = await ws.newWorkFile(name);
        await File(out).writeAsBytes(r.bytes, flush: true);
        final probe = probeImage(r.bytes);
        return ToolResult(
          headline: 'Photo saved · ${r.width} × ${r.height} px',
          outputs: [OutputFile(out, name)],
          checks: [
            Check('${probe.width} × ${probe.height} px, ${formatBytes(r.bytes.length)}', probe.width == r.width),
            if (widget.backgroundMode && _bgColor == null) Check('Transparent background', probe.hasAlpha),
          ],
          notes: r.notes,
        );
      },
    );
  }

  Widget _cropView() => Card(
    color: Colors.black,
    child: Padding(
      padding: const EdgeInsets.all(Gaps.m),
      child: CropBox(
        image: MemoryImage(_img!.proxy),
        imageSize: Size(_img!.width.toDouble(), _img!.height.toDouble()),
        rect: _crop!,
        aspect: _aspect,
        onChanged: (r) => _changed(() => _crop = r),
      ),
    ),
  );

  Widget _previewView() {
    final shown = _comparing ? _img!.proxy : (_preview ?? _img!.proxy);
    return GestureDetector(
      onLongPressStart: (_) => setState(() => _comparing = true),
      onLongPressEnd: (_) => setState(() => _comparing = false),
      child: Card(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _Checkerboard(),
            Padding(
              padding: const EdgeInsets.all(Gaps.m),
              child: Image.memory(shown, fit: BoxFit.contain, gaplessPlayback: true),
            ),
            Positioned(
              left: Gaps.m,
              top: Gaps.m,
              child: Pill(_comparing ? 'Original' : 'Hold to compare', icon: Icons.compare_rounded),
            ),
            if (_masking) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }

  List<Widget> _cropOptions() => [
    Wrap(
      spacing: Gaps.s,
      runSpacing: Gaps.s,
      children: [
        for (final e in _aspects.entries)
          ChoiceChip(label: Text(e.key), selected: _aspect == e.value, onSelected: (_) => _setAspect(e.value)),
      ],
    ),
    const SizedBox(height: Gaps.m),
    Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton.filledTonal(
          tooltip: 'Rotate left',
          icon: const Icon(Icons.rotate_left_rounded),
          onPressed: () => _changed(() => _rotate = (_rotate + 270) % 360),
        ),
        IconButton.filledTonal(
          tooltip: 'Rotate right',
          icon: const Icon(Icons.rotate_right_rounded),
          onPressed: () => _changed(() => _rotate = (_rotate + 90) % 360),
        ),
        IconButton.filledTonal(
          tooltip: 'Flip horizontally',
          isSelected: _flipH,
          icon: const Icon(Icons.flip_rounded),
          onPressed: () => _changed(() => _flipH = !_flipH),
        ),
        IconButton.filledTonal(
          tooltip: 'Flip vertically',
          isSelected: _flipV,
          icon: Transform.rotate(angle: math.pi / 2, child: const Icon(Icons.flip_rounded)),
          onPressed: () => _changed(() => _flipV = !_flipV),
        ),
      ],
    ),
    if (_rotate != 0 || _flipH || _flipV)
      Padding(
        padding: const EdgeInsets.only(top: Gaps.s),
        child: Text(
          'Rotation and flips are applied after cropping. See them in Adjust.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ),
  ];

  List<Widget> _adjustOptions() => [
    LabeledSlider(
      label: 'Brightness',
      value: _brightness,
      min: -1,
      max: 1,
      format: _pct,
      onChanged: (v) => _changed(() => _brightness = v),
    ),
    LabeledSlider(
      label: 'Contrast',
      value: _contrast,
      min: -1,
      max: 1,
      format: _pct,
      onChanged: (v) => _changed(() => _contrast = v),
    ),
    LabeledSlider(
      label: 'Saturation',
      value: _saturation,
      min: -1,
      max: 1,
      format: _pct,
      onChanged: (v) => _changed(() => _saturation = v),
    ),
    LabeledSlider(
      label: 'Sharpness',
      value: _sharpness,
      min: 0,
      max: 1,
      format: _pct,
      onChanged: (v) => _changed(() => _sharpness = v),
    ),
    TextButton.icon(
      onPressed: () => _changed(() {
        _brightness = _contrast = _saturation = _sharpness = 0;
      }),
      icon: const Icon(Icons.restart_alt_rounded),
      label: const Text('Reset adjustments'),
    ),
  ];

  static String _pct(double v) => '${v >= 0 ? '+' : ''}${(v * 100).round()}';

  List<Widget> _backgroundOptions() => [
    if (_maskCoverage != null && _maskCoverage! < 0.03)
      const Padding(
        padding: EdgeInsets.only(bottom: Gaps.m),
        child: MessageBanner(
          kind: BannerKind.warning,
          message: 'No person was clearly detected in this photo. The result may be empty.',
        ),
      ),
    OptionGroup(
      title: 'New background',
      children: [
        Wrap(
          spacing: Gaps.m,
          runSpacing: Gaps.m,
          children: [
            for (final c in const [null, 0xFFFFFFFF, 0xFFDDE7F3, 0xFF2F6BD0, 0xFFD32F2F, 0xFFBDBDBD])
              Semantics(
                button: true,
                selected: _bgColor == c,
                label: c == null ? 'Transparent' : 'Colour',
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _changed(() {
                    _bgColor = c;
                    _format = c == null ? ImgFormat.png : ImgFormat.jpeg;
                  }),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c == null ? null : Color(c),
                      border: Border.all(
                        color: _bgColor == c
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                        width: _bgColor == c ? 3 : 1,
                      ),
                    ),
                    child: c == null ? const ClipOval(child: _Checkerboard()) : null,
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  ];
}

class _Checkerboard extends StatelessWidget {
  const _Checkerboard();
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _CheckerPainter());
}

class _CheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 10.0;
    final a = Paint()..color = const Color(0xFFEEEEEE);
    final b = Paint()..color = const Color(0xFFFFFFFF);
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), ((x + y) / cell).round().isEven ? a : b);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
