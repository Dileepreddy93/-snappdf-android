import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/jobs/job.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import '../image/engine/image_engine.dart';
import '../image/engine/image_format.dart';
import '../image/image_tools.dart';
import 'batch_workflow.dart';

final _presetStoreProvider = Provider<JsonFileStore>(
  (ref) => JsonFileStore(File(p.join(ref.watch(workspaceProvider).dataDir.path, 'batch_presets.json'))),
);

class BatchScreen extends ConsumerStatefulWidget {
  const BatchScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends ConsumerState<BatchScreen> {
  late List<InputFile> _inputs = widget.initial.where((f) => f.kind == FileKind.image).toList();
  List<InputFile> _failed = [];
  List<BatchPreset> _saved = [];

  bool _doResize = true;
  final _w = TextEditingController(text: '1600');
  final _h = TextEditingController(text: '1600');
  ResizeMode _mode = ResizeMode.fit;
  bool _doCompress = true;
  final _size = TextEditingController(text: '300');
  bool _sizeMb = false;
  int _quality = 85;
  ImgFormat? _format = ImgFormat.jpeg;
  final _rename = TextEditingController(text: '{name}');
  bool _exportFolder = false;

  @override
  void initState() {
    super.initState();
    _loadPresets();
  }

  Future<void> _loadPresets() async {
    final data = await ref.read(_presetStoreProvider).read();
    final list = [
      for (final j in (data?['presets'] as List? ?? const [])) BatchPreset.fromJson((j as Map).cast<String, Object?>()),
    ];
    if (mounted) setState(() => _saved = list);
  }

  Future<void> _savePresets() => ref.read(_presetStoreProvider).write({
    'presets': [for (final p in _saved) p.toJson()],
  });

  BatchPreset _current(String name) => BatchPreset(
    name: name,
    resize: _doResize ? ResizeSpec(width: int.tryParse(_w.text), height: int.tryParse(_h.text), mode: _mode) : null,
    targetBytes: _doCompress ? SizeLimitField.bytes(_size.text, _sizeMb) : null,
    quality: _quality,
    format: _format,
    renamePattern: _rename.text,
  );

  void _apply(BatchPreset preset) {
    setState(() {
      _doResize = preset.resize != null;
      if (preset.resize != null) {
        _w.text = '${preset.resize!.width ?? ''}';
        _h.text = '${preset.resize!.height ?? ''}';
        _mode = preset.resize!.mode;
      }
      _doCompress = preset.targetBytes != null;
      if (preset.targetBytes != null) {
        final kb = preset.targetBytes! / 1024;
        _sizeMb = kb >= 1024;
        _size.text = _sizeMb ? (kb / 1024).toStringAsFixed(1) : kb.round().toString();
      }
      _quality = preset.quality;
      _format = preset.format;
      _rename.text = preset.renamePattern;
    });
    showMessage(context, 'Applied “${preset.name}”');
  }

  Future<void> _saveAsPreset() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save preset'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Preset name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => _saved = [..._saved.where((p) => p.name != name), _current(name)]);
    await _savePresets();
  }

  String? _canRun() {
    if (_inputs.isEmpty) return 'Add images';
    if (_doResize && int.tryParse(_w.text) == null && int.tryParse(_h.text) == null) return 'Enter a width or height';
    if (_doCompress && SizeLimitField.bytes(_size.text, _sizeMb) == null) return 'Enter the maximum size';
    return null;
  }

  Future<ToolResult> _run(BuildContext context, JobHandle job) async {
    final api = ref.read(nativeApiProvider);
    final ws = ref.read(workspaceProvider);
    final preset = _current('current');
    ({String uri, String? name})? folder;
    if (_exportFolder) {
      folder = await api.pickFolder();
      if (folder == null) throw NativeError(NativeError.cancelled, 'Cancelled.');
    }
    final spec = preset.toSpec();
    final outputs = <OutputFile>[];
    final checks = <Check>[];
    final notes = <String>[];
    final failed = <InputFile>[];
    final taken = <String>{};
    final now = DateTime.now();
    for (var i = 0; i < _inputs.length; i++) {
      job.throwIfCancelled();
      final f = _inputs[i];
      job.report(i, _inputs.length, '${i + 1} of ${_inputs.length}: ${f.name}');
      try {
        final r = await processImage(await File(f.path).readAsBytes(), spec);
        final name = applyRenamePattern(preset.renamePattern, f.name, i, r.format.extension, now, taken);
        final out = await ws.newWorkFile(name);
        await File(out).writeAsBytes(r.bytes, flush: true);
        outputs.add(OutputFile(out, name));
        if (!r.targetMet) {
          checks.add(Check('$name: ${formatBytes(r.bytes.length)} exceeds the limit', false));
        }
        notes.addAll(r.notes.map((n) => '$name: $n'));
      } catch (e) {
        failed.add(f);
        checks.add(Check('${f.name}: $e', false));
      }
    }
    checks.insert(0, Check('${outputs.length} of ${_inputs.length} images processed', failed.isEmpty));
    if (folder != null && outputs.isNotEmpty) {
      job.message.value = 'Saving to ${folder.name ?? 'folder'}…';
      final names = await api.exportToFolder(folder.uri, [for (final o in outputs) (path: o.path, name: o.name)]);
      checks.add(
        Check('Saved ${names.length} files to ${folder.name ?? 'the chosen folder'}', names.length == outputs.length),
      );
      final renamed = [
        for (var i = 0; i < names.length; i++)
          if (names[i] != outputs[i].name) names[i],
      ];
      if (renamed.isNotEmpty) {
        notes.add('${renamed.length} file(s) already existed in the folder and were saved with a new name.');
      }
    }
    _failed = failed;
    if (failed.isNotEmpty) notes.add('Tap “Start over” to retry the ${failed.length} failed file(s).');
    return ToolResult(
      headline: 'Batch finished: ${outputs.length} images',
      outputs: outputs,
      checks: checks,
      notes: notes,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ToolScaffold(
      title: 'Batch workflow',
      about:
          'Process many photos in one go: resize, compress to a size limit, convert and rename, then save them to '
          'a folder. Save your settings as a preset to reuse them. Each file is handled separately, so one failure does '
          'not stop the batch.',
      actionLabel: _inputs.isEmpty ? 'Run' : 'Run on ${_inputs.length} images',
      actionIcon: Icons.playlist_play_rounded,
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
            emptyLabel: 'Add photos',
            onChanged: (l) => setState(() => _inputs = l),
          ),
          const SizedBox(height: Gaps.xl),
          Text('Presets', style: t.titleSmall),
          const SizedBox(height: Gaps.s),
          Wrap(
            spacing: Gaps.s,
            runSpacing: Gaps.s,
            children: [
              for (final p in [...builtInPresets, ..._saved])
                InputChip(
                  label: Text(p.name),
                  onPressed: () => _apply(p),
                  onDeleted: _saved.contains(p)
                      ? () async {
                          setState(() => _saved = _saved.where((x) => x != p).toList());
                          await _savePresets();
                        }
                      : null,
                ),
              ActionChip(
                avatar: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Save current'),
                onPressed: _saveAsPreset,
              ),
            ],
          ),
          const SizedBox(height: Gaps.xl),
          _Step(
            number: 1,
            title: 'Resize',
            enabled: _doResize,
            onToggle: (v) => setState(() => _doResize = v),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _w,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Max width'),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: Gaps.m),
                    Expanded(
                      child: TextField(
                        controller: _h,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Max height'),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Gaps.m),
                SegmentedButton<ResizeMode>(
                  segments: const [
                    ButtonSegment(value: ResizeMode.fit, label: Text('Fit')),
                    ButtonSegment(value: ResizeMode.fill, label: Text('Fill')),
                    ButtonSegment(value: ResizeMode.pad, label: Text('Pad')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (v) => setState(() => _mode = v.first),
                ),
              ],
            ),
          ),
          _Step(
            number: 2,
            title: 'Compress to a maximum size',
            enabled: _doCompress,
            onToggle: (v) => setState(() => _doCompress = v),
            child: SizeLimitField(
              controller: _size,
              inMb: _sizeMb,
              onUnit: (v) => setState(() => _sizeMb = v),
              onChanged: () => setState(() {}),
            ),
          ),
          _Step(
            number: 3,
            title: 'Format',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FormatPicker(value: _format, onChanged: (v) => setState(() => _format = v)),
                if (!_doCompress && (_format?.lossy ?? true))
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
          ),
          _Step(
            number: 4,
            title: 'Rename',
            child: TextField(
              controller: _rename,
              decoration: const InputDecoration(
                labelText: 'Name pattern',
                helperText: '{name} original name · {n} number · {date} today',
              ),
            ),
          ),
          _Step(
            number: 5,
            title: 'Export',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _exportFolder,
              onChanged: (v) => setState(() => _exportFolder = v),
              title: const Text('Save to a folder on my device'),
              subtitle: const Text(
                'You choose the folder when the batch starts. Results are always kept in SnapPDF files too.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.title, required this.child, this.enabled = true, this.onToggle});
  final int number;
  final String title;
  final Widget child;
  final bool enabled;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gaps.m),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gaps.l, Gaps.s, Gaps.l, Gaps.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(radius: 13, child: Text('$number', style: t.labelMedium)),
                  const SizedBox(width: Gaps.m),
                  Expanded(child: Text(title, style: t.titleSmall)),
                  if (onToggle != null) Switch(value: enabled, onChanged: onToggle),
                ],
              ),
              if (enabled) ...[const SizedBox(height: Gaps.m), child],
            ],
          ),
        ),
      ),
    );
  }
}
