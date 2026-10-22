import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import 'engine/image_engine.dart';
import 'engine/image_format.dart';
import 'engine/image_metadata.dart';
import 'overlay_render.dart';

/// Size limit entry in KB or MB.
class SizeLimitField extends StatelessWidget {
  const SizeLimitField({
    super.key,
    required this.controller,
    required this.inMb,
    required this.onUnit,
    required this.onChanged,
    this.label = 'Maximum size',
  });
  final TextEditingController controller;
  final bool inMb;
  final ValueChanged<bool> onUnit;
  final VoidCallback onChanged;
  final String label;

  static int? bytes(String text, bool inMb) {
    final v = double.tryParse(text.replaceAll(',', '.'));
    if (v == null || v <= 0) return null;
    return (v * (inMb ? 1024 * 1024 : 1024)).round();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label),
          onChanged: (_) => onChanged(),
        ),
      ),
      const SizedBox(width: Gaps.m),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('KB')),
          ButtonSegment(value: true, label: Text('MB')),
        ],
        selected: {inMb},
        onSelectionChanged: (v) => onUnit(v.first),
      ),
    ],
  );
}

/// Output format chooser; null means "same as original".
class FormatPicker extends StatelessWidget {
  const FormatPicker({super.key, required this.value, required this.onChanged, this.allowKeep = true});
  final ImgFormat? value;
  final ValueChanged<ImgFormat?> onChanged;
  final bool allowKeep;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: Gaps.s,
    runSpacing: Gaps.s,
    children: [
      if (allowKeep)
        ChoiceChip(label: const Text('Same as original'), selected: value == null, onSelected: (_) => onChanged(null)),
      for (final f in ImgFormat.values)
        ChoiceChip(label: Text(f.label), selected: value == f, onSelected: (_) => onChanged(f)),
    ],
  );
}

enum ImageToolKind { compress, resize, convert, watermark, metadata }

class ImageBatchScreen extends ConsumerStatefulWidget {
  const ImageBatchScreen({super.key, required this.kind, this.initial = const []});
  final ImageToolKind kind;
  final List<InputFile> initial;

  @override
  ConsumerState<ImageBatchScreen> createState() => _ImageBatchScreenState();
}

enum _ResizeBy { pixels, percent }

class _ImageBatchScreenState extends ConsumerState<ImageBatchScreen> {
  late List<InputFile> _inputs = widget.initial.where((f) => f.kind == FileKind.image).toList();
  List<InputFile> _failed = [];

  // Common
  ImgFormat? _format;
  late int _quality = ref.read(settingsProvider).defaultJpegQuality;

  // Compress
  bool _useTarget = true;
  final _target = TextEditingController(text: '200');
  bool _targetMb = false;
  bool _allowShrink = true;

  // Resize
  _ResizeBy _resizeBy = _ResizeBy.pixels;
  final _w = TextEditingController();
  final _h = TextEditingController();
  ResizeMode _mode = ResizeMode.fit;
  double _percent = 50;

  // Convert
  int _background = 0xFFFFFFFF;

  // Watermark
  final _wmText = TextEditingController(text: '© ');
  double _wmOpacity = 0.5;
  double _wmSize = 0.35;
  String _wmPos = 'bottom-right';
  int _wmColor = 0xFFFFFFFF;

  // Metadata
  bool _keepIcc = true;
  final Map<String, MetadataReport> _reports = {};

  String get _title => switch (widget.kind) {
    ImageToolKind.compress => 'Compress images',
    ImageToolKind.resize => 'Resize images',
    ImageToolKind.convert => 'Convert images',
    ImageToolKind.watermark => 'Watermark photos',
    ImageToolKind.metadata => 'Photo metadata',
  };

  String get _about => switch (widget.kind) {
    ImageToolKind.compress =>
      'Reduces file size to a maximum you choose (for example 200 KB for an application form). '
          'SnapPDF searches for the highest quality that fits, and shrinks the dimensions only if quality alone is not enough. '
          'If a limit cannot be reached you get the closest result and an explanation.',
    ImageToolKind.resize =>
      'Changes the pixel dimensions. “Fit” keeps the aspect ratio inside the box, “Fill” crops to '
          'exactly the size, and “Stretch” forces the size even if the image gets distorted.',
    ImageToolKind.convert => 'Converts between JPG, PNG and WebP. JPG cannot store transparency, so transparent areas are filled with the colour you choose.',
    ImageToolKind.watermark => 'Adds a text watermark to each photo.',
    ImageToolKind.metadata =>
      'Shows hidden information stored in photos (camera, date, GPS location) and removes it '
          'without recompressing the image, so there is no quality loss. Orientation is kept so photos stay upright.',
  };

  int? get _targetBytes => SizeLimitField.bytes(_target.text, _targetMb);

  Future<void> _inspect(List<InputFile> list) async {
    for (final f in list) {
      try {
        final bytes = await File(f.path).readAsBytes();
        _reports[f.path] = inspectMetadata(bytes);
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  String? _canRun() {
    if (_inputs.isEmpty) return 'Add at least one image';
    switch (widget.kind) {
      case ImageToolKind.compress:
        if (_useTarget && _targetBytes == null) return 'Enter a maximum size';
      case ImageToolKind.resize:
        if (_resizeBy == _ResizeBy.pixels) {
          final w = int.tryParse(_w.text), h = int.tryParse(_h.text);
          if (w == null && h == null) return 'Enter a width or height';
          if ((w != null && w <= 0) || (h != null && h <= 0)) return 'Sizes must be positive';
          if (_mode != ResizeMode.fit && (w == null || h == null)) return 'Enter both width and height';
        }
      case ImageToolKind.convert:
        if (_format == null) return 'Choose a target format';
      case ImageToolKind.watermark:
        if (_wmText.text.trim().isEmpty) return 'Enter watermark text';
      case ImageToolKind.metadata:
        break;
    }
    return null;
  }

  Future<ImageSpec> _spec() async {
    switch (widget.kind) {
      case ImageToolKind.compress:
        return ImageSpec(
          format: _format,
          quality: _useTarget ? 92 : _quality,
          targetBytes: _useTarget ? _targetBytes : null,
          allowDownscaleForSize: _allowShrink,
        );
      case ImageToolKind.resize:
        return ImageSpec(
          format: _format,
          quality: _quality,
          resize: _resizeBy == _ResizeBy.percent
              ? ResizeSpec(percent: _percent)
              : ResizeSpec(
                  width: int.tryParse(_w.text),
                  height: int.tryParse(_h.text),
                  mode: _mode,
                  allowUpscale: true,
                ),
        );
      case ImageToolKind.convert:
        return ImageSpec(format: _format, quality: _quality, background: _background);
      case ImageToolKind.watermark:
        final (cx, cy) = switch (_wmPos) {
          'center' => (0.5, 0.5),
          'bottom-left' => (0.05 + _wmSize / 2, 0.92),
          'top-right' => (0.95 - _wmSize / 2, 0.08),
          _ => (0.95 - _wmSize / 2, 0.92),
        };
        final overlay = await renderTextOverlay(
          _wmText.text.trim(),
          color: Color(_wmColor),
          opacity: _wmOpacity,
          centerX: cx,
          centerY: cy,
          widthFraction: _wmSize,
          tile: _wmPos == 'tile',
          rotationDegrees: _wmPos == 'tile' ? -30 : 0,
        );
        return ImageSpec(format: _format, quality: _quality, overlay: overlay);
      case ImageToolKind.metadata:
        return const ImageSpec();
    }
  }

  Future<ToolResult> _run(BuildContext context, job) async {
    final ws = ref.read(workspaceProvider);
    final outputs = <OutputFile>[];
    final checks = <Check>[];
    final notes = <String>[];
    final failed = <InputFile>[];
    final spec = await _spec();
    final suffix = switch (widget.kind) {
      ImageToolKind.compress => 'compressed',
      ImageToolKind.resize => 'resized',
      ImageToolKind.convert => '',
      ImageToolKind.watermark => 'watermarked',
      ImageToolKind.metadata => 'clean',
    };
    var before = 0, after = 0;
    for (var i = 0; i < _inputs.length; i++) {
      job.throwIfCancelled();
      final f = _inputs[i];
      job.report(i, _inputs.length, 'Processing ${f.name} (${i + 1}/${_inputs.length})');
      try {
        final bytes = await File(f.path).readAsBytes();
        before += bytes.length;
        late Uint8List outBytes;
        late String ext;
        if (widget.kind == ImageToolKind.metadata) {
          final fmt = ImgFormat.sniff(bytes);
          if (fmt == null) throw ImageEngineException('Only JPG, PNG and WebP metadata can be removed.');
          outBytes = stripMetadataLossless(bytes, keepColorProfile: _keepIcc);
          ext = fmt.extension;
          final after = inspectMetadata(outBytes);
          final clean =
              !after.hasGps &&
              after.blocks.every((b) => b.kind == 'ICC profile' || (b.kind == 'EXIF' && after.tags.length <= 1));
          checks.add(Check('${f.name}: metadata removed${after.orientation != 1 ? ' (orientation kept)' : ''}', clean));
        } else {
          final r = await processImage(bytes, spec);
          outBytes = r.bytes;
          ext = r.format.extension;
          final label = _inputs.length > 1 ? '${f.name}: ' : '';
          checks.add(Check('$label${r.width} × ${r.height} px, ${formatBytes(r.bytes.length)}', r.targetMet));
          for (final n in r.notes) {
            notes.add(_inputs.length > 1 ? '${f.name}: $n' : n);
          }
          // Re-decode to verify the file is valid and matches what we report.
          final probe = probeImage(r.bytes);
          if (probe.width != r.width || probe.height != r.height) {
            checks.add(Check('$label output verification failed', false));
          }
        }
        after += outBytes.length;
        final name = derivedName(f.name, suffix, extension: ext);
        final out = await ws.newWorkFile(name);
        await File(out).writeAsBytes(outBytes, flush: true);
        outputs.add(OutputFile(out, name));
      } catch (e) {
        failed.add(f);
        checks.add(Check('${f.name}: $e', false));
      }
    }
    _failed = failed;
    if (failed.isNotEmpty) {
      notes.add(
        '${failed.length} file${failed.length == 1 ? '' : 's'} failed. Tap “Start over” to retry only the failed files.',
      );
    }
    return ToolResult(
      headline: outputs.isEmpty
          ? 'No images were processed'
          : '${outputs.length} image${outputs.length == 1 ? '' : 's'} ready · ${formatBytes(before)} → ${formatBytes(after)}',
      outputs: outputs,
      checks: checks,
      notes: notes,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ToolScaffold(
      title: _title,
      about: _about,
      actionLabel: _inputs.length > 1 ? 'Process ${_inputs.length} images' : 'Process',
      actionIcon: Icons.auto_fix_high_rounded,
      canRun: _canRun,
      onReset: () => setState(() {
        if (_failed.isNotEmpty) _inputs = _failed;
      }),
      run: _run,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InputsCard(
            inputs: _inputs,
            accept: Accept.image,
            multiple: true,
            emptyLabel: 'Add images',
            onAdded: widget.kind == ImageToolKind.metadata
                ? (l) async {
                    await _inspect(l);
                    return l;
                  }
                : null,
            onChanged: (l) => setState(() => _inputs = l),
          ),
          const SizedBox(height: Gaps.xl),
          ..._options(t),
        ],
      ),
    );
  }

  List<Widget> _options(TextTheme t) {
    switch (widget.kind) {
      case ImageToolKind.compress:
        return [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Maximum size')),
              ButtonSegment(value: false, label: Text('Quality')),
            ],
            selected: {_useTarget},
            onSelectionChanged: (v) => setState(() => _useTarget = v.first),
          ),
          const SizedBox(height: Gaps.l),
          if (_useTarget) ...[
            SizeLimitField(
              controller: _target,
              inMb: _targetMb,
              onUnit: (v) => setState(() => _targetMb = v),
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: Gaps.s),
            Wrap(
              spacing: Gaps.s,
              children: [
                for (final kb in [20, 50, 100, 200, 500])
                  ActionChip(
                    label: Text('$kb KB'),
                    onPressed: () => setState(() {
                      _target.text = '$kb';
                      _targetMb = false;
                    }),
                  ),
                ActionChip(
                  label: const Text('1 MB'),
                  onPressed: () => setState(() {
                    _target.text = '1';
                    _targetMb = true;
                  }),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _allowShrink,
              onChanged: (v) => setState(() => _allowShrink = v),
              title: const Text('Allow smaller dimensions if needed'),
              subtitle: const Text('Keeps quality higher; turn off to keep the exact pixel size'),
            ),
          ] else
            LabeledSlider(
              label: 'Quality',
              value: _quality.toDouble(),
              min: 10,
              max: 100,
              divisions: 18,
              onChanged: (v) => setState(() => _quality = v.round()),
            ),
          OptionGroup(
            title: 'Format',
            children: [FormatPicker(value: _format, onChanged: (v) => setState(() => _format = v))],
          ),
          if (_format == ImgFormat.png && _useTarget)
            const MessageBanner(
              message: 'PNG is lossless: size limits are met by reducing colours or dimensions. JPG or WebP usually give much smaller files.',
            ),
        ];
      case ImageToolKind.resize:
        return [
          SegmentedButton<_ResizeBy>(
            segments: const [
              ButtonSegment(value: _ResizeBy.pixels, label: Text('Pixels')),
              ButtonSegment(value: _ResizeBy.percent, label: Text('Percentage')),
            ],
            selected: {_resizeBy},
            onSelectionChanged: (v) => setState(() => _resizeBy = v.first),
          ),
          const SizedBox(height: Gaps.l),
          if (_resizeBy == _ResizeBy.pixels) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _w,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Width (px)'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: Gaps.m),
                  child: Icon(Icons.close_rounded, size: 18),
                ),
                Expanded(
                  child: TextField(
                    controller: _h,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Height (px)'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gaps.s),
            Wrap(
              spacing: Gaps.s,
              children: [
                for (final s in const [(1920, 1080), (1280, 720), (1080, 1080), (800, 600), (600, 600)])
                  ActionChip(
                    label: Text('${s.$1}×${s.$2}'),
                    onPressed: () => setState(() {
                      _w.text = '${s.$1}';
                      _h.text = '${s.$2}';
                    }),
                  ),
              ],
            ),
            const SizedBox(height: Gaps.l),
            OptionGroup(
              title: 'Aspect ratio',
              children: [
                SegmentedButton<ResizeMode>(
                  segments: const [
                    ButtonSegment(value: ResizeMode.fit, label: Text('Fit')),
                    ButtonSegment(value: ResizeMode.fill, label: Text('Fill')),
                    ButtonSegment(value: ResizeMode.stretch, label: Text('Stretch')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (v) => setState(() => _mode = v.first),
                ),
                const SizedBox(height: Gaps.s),
                Text(switch (_mode) {
                  ResizeMode.fit => 'Keeps proportions; the image fits inside the size.',
                  ResizeMode.fill => 'Exactly this size; edges are cropped to keep proportions.',
                  ResizeMode.stretch => 'Exactly this size; the image may look distorted.',
                  ResizeMode.pad => 'Exactly this size; the image fits inside with empty margins.',
                }, style: t.bodySmall),
              ],
            ),
          ] else
            LabeledSlider(
              label: 'Scale',
              value: _percent,
              min: 5,
              max: 200,
              divisions: 39,
              format: (v) => '${v.round()}%',
              onChanged: (v) => setState(() => _percent = v),
            ),
          OptionGroup(
            title: 'Format',
            children: [FormatPicker(value: _format, onChanged: (v) => setState(() => _format = v))],
          ),
        ];
      case ImageToolKind.convert:
        return [
          OptionGroup(
            title: 'Convert to',
            children: [FormatPicker(value: _format, allowKeep: false, onChanged: (v) => setState(() => _format = v))],
          ),
          if (_format?.lossy ?? false)
            LabeledSlider(
              label: 'Quality',
              value: _quality.toDouble(),
              min: 10,
              max: 100,
              divisions: 18,
              onChanged: (v) => setState(() => _quality = v.round()),
            ),
          if (_format == ImgFormat.jpeg)
            OptionGroup(
              title: 'Fill transparent areas with',
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0xFFFFFFFF, label: Text('White')),
                    ButtonSegment(value: 0xFF000000, label: Text('Black')),
                  ],
                  selected: {_background},
                  onSelectionChanged: (v) => setState(() => _background = v.first),
                ),
              ],
            ),
        ];
      case ImageToolKind.watermark:
        return [
          TextField(
            controller: _wmText,
            decoration: const InputDecoration(labelText: 'Watermark text'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Gaps.l),
          OptionGroup(
            title: 'Position',
            children: [
              Wrap(
                spacing: Gaps.s,
                runSpacing: Gaps.s,
                children: [
                  for (final e in const {
                    'bottom-right': 'Bottom right',
                    'bottom-left': 'Bottom left',
                    'top-right': 'Top right',
                    'center': 'Centre',
                    'tile': 'Repeat',
                  }.entries)
                    ChoiceChip(
                      label: Text(e.value),
                      selected: _wmPos == e.key,
                      onSelected: (_) => setState(() => _wmPos = e.key),
                    ),
                ],
              ),
            ],
          ),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0xFFFFFFFF, label: Text('White')),
              ButtonSegment(value: 0xFF000000, label: Text('Black')),
              ButtonSegment(value: 0xFFE53935, label: Text('Red')),
            ],
            selected: {_wmColor},
            onSelectionChanged: (v) => setState(() => _wmColor = v.first),
          ),
          const SizedBox(height: Gaps.l),
          LabeledSlider(
            label: 'Size',
            value: _wmSize,
            min: 0.1,
            max: 0.9,
            format: (v) => '${(v * 100).round()}% of width',
            onChanged: (v) => setState(() => _wmSize = v),
          ),
          LabeledSlider(
            label: 'Opacity',
            value: _wmOpacity,
            min: 0.1,
            max: 1,
            format: (v) => '${(v * 100).round()}%',
            onChanged: (v) => setState(() => _wmOpacity = v),
          ),
          OptionGroup(
            title: 'Format',
            children: [FormatPicker(value: _format, onChanged: (v) => setState(() => _format = v))],
          ),
        ];
      case ImageToolKind.metadata:
        return [
          for (final f in _inputs)
            if (_reports[f.path] != null) _MetadataCard(name: f.name, report: _reports[f.path]!),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _keepIcc,
            onChanged: (v) => setState(() => _keepIcc = v),
            title: const Text('Keep colour profile'),
            subtitle: const Text('Recommended: keeps colours accurate. Contains no personal data.'),
          ),
        ];
    }
  }
}

class _MetadataCard extends StatelessWidget {
  const _MetadataCard({required this.name, required this.report});
  final String name;
  final MetadataReport report;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gaps.m),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Gaps.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: Gaps.s),
              if (report.hasGps)
                const Padding(
                  padding: EdgeInsets.only(bottom: Gaps.s),
                  child: Pill('Contains GPS location', icon: Icons.location_on_outlined, tone: Tone.danger),
                ),
              if (report.blocks.isEmpty)
                Text('No metadata found.', style: t.bodyMedium)
              else
                Wrap(
                  spacing: Gaps.s,
                  runSpacing: Gaps.s,
                  children: [for (final b in report.blocks) Pill('${b.kind} · ${formatBytes(b.bytes)}')],
                ),
              if (report.tags.isNotEmpty) ...[
                const SizedBox(height: Gaps.s),
                for (final e in report.tags.entries.take(12)) InfoRow(e.key, e.value),
                if (report.tags.length > 12) Text('…and ${report.tags.length - 12} more', style: t.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String outputNameFor(String input, ImgFormat format, String suffix) =>
    derivedName(p.basename(input), suffix, extension: format.extension);
