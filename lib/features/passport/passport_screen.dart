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
import '../image/crop_box.dart';
import '../image/engine/image_engine.dart';
import '../image/engine/image_format.dart';
import '../image/photo_editor_screen.dart';

/// Photo size specification.
class PhotoPreset {
  const PhotoPreset(this.label, {this.widthMm, this.heightMm, this.widthPx, this.heightPx, this.note});
  final String label;
  final double? widthMm;
  final double? heightMm;
  final int? widthPx;
  final int? heightPx;
  final String? note;

  bool get isPixels => widthPx != null;

  /// Output pixels at [dpi] (for mm presets).
  (int, int) pixels(int dpi) =>
      isPixels ? (widthPx!, heightPx!) : ((widthMm! / 25.4 * dpi).round(), (heightMm! / 25.4 * dpi).round());

  double get aspect => isPixels ? widthPx! / heightPx! : widthMm! / heightMm!;
}

/// Common sizes. These are starting points only: requirements change and
/// differ by authority, so the UI asks users to check the current rules.
const photoPresets = [
  PhotoPreset(
    '35 × 45 mm',
    widthMm: 35,
    heightMm: 45,
    note: 'Common for passports and visas in India, the UK, the EU and many other countries',
  ),
  PhotoPreset(
    '2 × 2 in (51 × 51 mm)',
    widthMm: 50.8,
    heightMm: 50.8,
    note: 'Used for US passports and visas, among others',
  ),
  PhotoPreset('35 × 35 mm', widthMm: 35, heightMm: 35),
  PhotoPreset('40 × 50 mm', widthMm: 40, heightMm: 50),
];

/// Lays out [count] copies of [photo] on a print sheet of [sheetW]×[sheetH]
/// pixels with [gap] spacing and thin cut lines. Returns how many fit.
({img.Image sheet, int placed}) composeSheet(img.Image photo, int sheetW, int sheetH, {int gap = 24, int? count}) {
  final sheet = img.Image(width: sheetW, height: sheetH, numChannels: 3);
  img.fill(sheet, color: img.ColorRgb8(255, 255, 255));
  final cols = math.max(0, (sheetW - gap) ~/ (photo.width + gap));
  final rows = math.max(0, (sheetH - gap) ~/ (photo.height + gap));
  final total = math.min(cols * rows, count ?? cols * rows);
  final usedW = cols * photo.width + (cols - 1) * gap;
  final usedH = rows * photo.height + (rows - 1) * gap;
  final ox = (sheetW - usedW) ~/ 2;
  final oy = (sheetH - usedH) ~/ 2;
  var placed = 0;
  for (var r = 0; r < rows && placed < total; r++) {
    for (var c = 0; c < cols && placed < total; c++) {
      final x = ox + c * (photo.width + gap);
      final y = oy + r * (photo.height + gap);
      img.compositeImage(sheet, photo, dstX: x, dstY: y);
      img.drawRect(
        sheet,
        x1: x - 1,
        y1: y - 1,
        x2: x + photo.width,
        y2: y + photo.height,
        color: img.ColorRgb8(190, 190, 190),
      );
      placed++;
    }
  }
  return (sheet: sheet, placed: placed);
}

class PassportPhotoScreen extends ConsumerStatefulWidget {
  const PassportPhotoScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<PassportPhotoScreen> createState() => _PassportPhotoScreenState();
}

class _PassportPhotoScreenState extends ConsumerState<PassportPhotoScreen> {
  InputFile? _input;
  LoadedImage? _img;
  Rect? _crop;
  int _presetIndex = 0;
  bool _custom = false;
  bool _customPx = false;
  final _cw = TextEditingController(text: '35');
  final _ch = TextEditingController(text: '45');
  int _dpi = 300;
  int? _bg = 0xFFFFFFFF; // null = keep original
  Uint8List? _mask;
  bool _masking = false;
  String? _error;
  bool _limit = false;
  final _maxKb = TextEditingController(text: '100');
  bool _sheet = true;
  String _sheetSize = '4x6';

  PhotoPreset get _preset {
    if (!_custom) return photoPresets[_presetIndex];
    final w = double.tryParse(_cw.text) ?? 35, h = double.tryParse(_ch.text) ?? 45;
    return _customPx
        ? PhotoPreset('Custom', widthPx: w.round().clamp(16, 6000), heightPx: h.round().clamp(16, 6000))
        : PhotoPreset('Custom', widthMm: w.clamp(5, 300).toDouble(), heightMm: h.clamp(5, 300).toDouble());
  }

  @override
  void initState() {
    super.initState();
    final f = widget.initial.where((x) => x.kind == FileKind.image).firstOrNull;
    if (f != null) WidgetsBinding.instance.addPostFrameCallback((_) => _open(f));
  }

  Future<void> _open(InputFile f) async {
    setState(() {
      _input = f;
      _img = null;
      _mask = null;
      _error = null;
    });
    try {
      final loaded = await LoadedImage.load(f.path);
      if (!mounted) return;
      setState(() {
        _img = loaded;
        _crop = centeredAspectRect(Size(loaded.width.toDouble(), loaded.height.toDouble()), _preset.aspect, fill: 0.9);
      });
      if (_bg != null) await _ensureMask();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _ensureMask() async {
    if (_mask != null || _input == null) return;
    setState(() => _masking = true);
    try {
      final out = await ref.read(workspaceProvider).newWorkFile('mask.png');
      final r = await ref.read(nativeApiProvider).personMask(_input!.path, out);
      final bytes = await File(r.path).readAsBytes();
      if (mounted) setState(() => _mask = bytes);
    } on NativeError catch (e) {
      if (mounted) setState(() => _error = 'Background could not be detected: ${e.message}');
    } finally {
      if (mounted) setState(() => _masking = false);
    }
  }

  void _presetChanged() {
    final img = _img;
    if (img == null) return;
    setState(
      () => _crop = centeredAspectRect(Size(img.width.toDouble(), img.height.toDouble()), _preset.aspect, fill: 0.9),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preset = _preset;
    final (pw, ph) = preset.pixels(_dpi);
    final t = Theme.of(context).textTheme;
    return ToolScaffold(
      title: 'Passport & ID photo',
      about:
          'Creates a correctly sized photo with a plain background, plus an optional print sheet. Requirements '
          '(size, head position, background colour, file size) differ between countries and change over time — always '
          'check the current rules of the authority you are applying to. SnapPDF does not verify face position or expression.',
      actionLabel: 'Create photo',
      actionIcon: Icons.portrait_rounded,
      canRun: () {
        if (_img == null) return 'Choose a portrait photo';
        if (_bg != null && _mask == null) {
          return _masking ? 'Detecting background…' : 'Background not detected; choose “Keep original”';
        }
        if (_limit && (double.tryParse(_maxKb.text) ?? 0) <= 0) return 'Enter the maximum size';
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InputsCard(
            inputs: [?_input],
            accept: Accept.image,
            emptyLabel: 'Take or choose a portrait photo',
            onChanged: (l) => l.isEmpty ? setState(() => _input = _img = null) : _open(l.first),
          ),
          const SizedBox(height: Gaps.l),
          const MessageBanner(
            message:
                'Use even lighting, a neutral expression, eyes open and the face looking straight at the camera. '
                'Check the official requirements before submitting.',
          ),
          if (_error != null) ...[
            const SizedBox(height: Gaps.l),
            MessageBanner(kind: BannerKind.error, message: _error!),
          ],
          const SizedBox(height: Gaps.xl),
          OptionGroup(
            title: 'Size',
            children: [
              Wrap(
                spacing: Gaps.s,
                runSpacing: Gaps.s,
                children: [
                  for (var i = 0; i < photoPresets.length; i++)
                    ChoiceChip(
                      label: Text(photoPresets[i].label),
                      selected: !_custom && _presetIndex == i,
                      onSelected: (_) {
                        setState(() {
                          _custom = false;
                          _presetIndex = i;
                        });
                        _presetChanged();
                      },
                    ),
                  ChoiceChip(
                    label: const Text('Custom'),
                    selected: _custom,
                    onSelected: (_) {
                      setState(() => _custom = true);
                      _presetChanged();
                    },
                  ),
                ],
              ),
              if (!_custom && preset.note != null) ...[
                const SizedBox(height: Gaps.s),
                Text(preset.note!, style: t.bodySmall),
              ],
              if (_custom) ...[
                const SizedBox(height: Gaps.m),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Millimetres')),
                    ButtonSegment(value: true, label: Text('Pixels')),
                  ],
                  selected: {_customPx},
                  onSelectionChanged: (v) {
                    setState(() {
                      _customPx = v.first;
                      if (_customPx) {
                        _cw.text = '200';
                        _ch.text = '230';
                      } else {
                        _cw.text = '35';
                        _ch.text = '45';
                      }
                    });
                    _presetChanged();
                  },
                ),
                const SizedBox(height: Gaps.m),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _cw,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: 'Width (${_customPx ? 'px' : 'mm'})'),
                        onChanged: (_) => _presetChanged(),
                      ),
                    ),
                    const SizedBox(width: Gaps.m),
                    Expanded(
                      child: TextField(
                        controller: _ch,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: 'Height (${_customPx ? 'px' : 'mm'})'),
                        onChanged: (_) => _presetChanged(),
                      ),
                    ),
                  ],
                ),
              ],
              if (!preset.isPixels) ...[
                const SizedBox(height: Gaps.m),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 300, label: Text('300 dpi (print)')),
                    ButtonSegment(value: 600, label: Text('600 dpi')),
                  ],
                  selected: {_dpi},
                  onSelectionChanged: (v) => setState(() => _dpi = v.first),
                ),
              ],
              const SizedBox(height: Gaps.s),
              Text('Output: $pw × $ph px', style: t.bodySmall),
            ],
          ),
          if (_img != null && _crop != null) ...[
            Text('Position the face inside the oval', style: t.titleSmall),
            const SizedBox(height: Gaps.s),
            SizedBox(
              height: 360,
              child: Card(
                color: Colors.black,
                child: Padding(
                  padding: const EdgeInsets.all(Gaps.m),
                  child: CropBox(
                    image: MemoryImage(_img!.proxy),
                    imageSize: Size(_img!.width.toDouble(), _img!.height.toDouble()),
                    rect: _crop!,
                    aspect: preset.aspect,
                    onChanged: (r) => setState(() => _crop = r),
                    guide: (r) => _FaceGuidePainter(r),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Gaps.xl),
          ],
          OptionGroup(
            title: 'Background',
            children: [
              Wrap(
                spacing: Gaps.s,
                runSpacing: Gaps.s,
                children: [
                  for (final e in const {
                    0xFFFFFFFF: 'White',
                    0xFFE9F0F8: 'Off-white',
                    0xFFCFE3F7: 'Light blue',
                    0xFFD9D9D9: 'Light grey',
                  }.entries)
                    ChoiceChip(
                      avatar: CircleAvatar(backgroundColor: Color(e.key), radius: 8),
                      label: Text(e.value),
                      selected: _bg == e.key,
                      onSelected: (_) {
                        setState(() => _bg = e.key);
                        _ensureMask();
                      },
                    ),
                  ChoiceChip(
                    label: const Text('Keep original'),
                    selected: _bg == null,
                    onSelected: (_) => setState(() => _bg = null),
                  ),
                ],
              ),
              if (_masking)
                const Padding(
                  padding: EdgeInsets.only(top: Gaps.s),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
          OptionGroup(
            title: 'File size',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _limit,
                onChanged: (v) => setState(() => _limit = v),
                title: const Text('Maximum file size'),
                subtitle: const Text('For online applications that set a KB limit'),
              ),
              if (_limit)
                TextField(
                  controller: _maxKb,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Maximum size (KB)'),
                  onChanged: (_) => setState(() {}),
                ),
            ],
          ),
          if (!preset.isPixels)
            OptionGroup(
              title: 'Print sheet',
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _sheet,
                  onChanged: (v) => setState(() => _sheet = v),
                  title: const Text('Also create a print sheet'),
                ),
                if (_sheet)
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: '4x6', label: Text('4 × 6 in')),
                      ButtonSegment(value: 'a4', label: Text('A4')),
                    ],
                    selected: {_sheetSize},
                    onSelectionChanged: (v) => setState(() => _sheetSize = v.first),
                  ),
              ],
            ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final api = ref.read(nativeApiProvider);
        final c = _crop!;
        final maxBytes = _limit ? ((double.tryParse(_maxKb.text) ?? 0) * 1024).round() : null;
        job.message.value = 'Creating photo…';
        final r = await processImage(
          _img!.bytes,
          ImageSpec(
            format: ImgFormat.jpeg,
            quality: 95,
            mask: _bg != null ? _mask : null,
            maskBackground: _bg,
            crop: CropRect(c.left.round(), c.top.round(), c.width.round(), c.height.round()),
            resize: ResizeSpec(width: pw, height: ph, mode: ResizeMode.fill, allowUpscale: true),
            targetBytes: maxBytes,
            allowDownscaleForSize: false,
          ),
        );
        final outputs = <OutputFile>[];
        final name = 'Photo_${pw}x$ph.jpg';
        final out = await ws.newWorkFile(name);
        await File(out).writeAsBytes(r.bytes, flush: true);
        outputs.add(OutputFile(out, name));
        final checks = <Check>[
          Check('Exactly $pw × $ph px', r.width == pw && r.height == ph),
          if (maxBytes != null)
            Check('At most ${formatBytes(maxBytes)} (got ${formatBytes(r.bytes.length)})', r.targetMet),
          if (_upscaled(c, pw))
            const Check('Source resolution is lower than the output size; the photo may look soft', false),
        ];
        if (_sheet && !preset.isPixels) {
          job.message.value = 'Creating print sheet…';
          final (sw, sh) = _sheetSize == '4x6'
              ? (6 * _dpi, 4 * _dpi)
              : ((297 / 25.4 * _dpi).round(), (210 / 25.4 * _dpi).round());
          final photoBytes = r.bytes;
          final gapPx = (2 / 25.4 * _dpi).round();
          final sheet = await Isolate.run(() {
            final photo = img.decodeJpg(photoBytes)!;
            final s = composeSheet(photo, sw, sh, gap: gapPx);
            return (img.encodeJpg(s.sheet, quality: 95), s.placed);
          });
          final sheetName = 'Photo sheet ${_sheetSize == '4x6' ? '4x6' : 'A4'} (${sheet.$2} photos).jpg';
          final sheetPath = await ws.newWorkFile(sheetName);
          await File(sheetPath).writeAsBytes(sheet.$1, flush: true);
          outputs.add(OutputFile(sheetPath, sheetName));
          // PDF at exact physical size for accurate printing.
          final pdfName = sheetName.replaceAll('.jpg', '.pdf');
          final pdfPath = await ws.newWorkFile(pdfName);
          await api.imagesToPdf([sheetPath], pdfPath, pageSize: 'dpi', dpi: _dpi.toDouble(), quality: 'original');
          outputs.add(OutputFile(pdfPath, pdfName));
          checks.add(Check('${sheet.$2} photos on the sheet', sheet.$2 > 0));
        }
        return ToolResult(
          headline: 'Photo ready · $pw × $ph px',
          outputs: outputs,
          checks: checks,
          notes: [
            ...r.notes,
            if (_sheet && !preset.isPixels)
              'Print the sheet at 100% / “actual size” (not “fit to page”) to keep the exact dimensions.',
          ],
        );
      },
    );
  }

  bool _upscaled(Rect crop, int outW) => crop.width < outW * 0.9;
}

class _FaceGuidePainter extends CustomPainter {
  _FaceGuidePainter(this.r);
  final Rect r;

  @override
  void paint(Canvas canvas, Size size) {
    final face = Rect.fromCenter(
      center: Offset(r.center.dx, r.top + r.height * 0.45),
      width: r.width * 0.55,
      height: r.height * 0.6,
    );
    canvas.drawOval(
      face,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final eye = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(r.left + r.width * 0.2, r.top + r.height * 0.4),
      Offset(r.right - r.width * 0.2, r.top + r.height * 0.4),
      eye,
    );
  }

  @override
  bool shouldRepaint(covariant _FaceGuidePainter old) => old.r != r;
}
