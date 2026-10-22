import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import 'signature_library.dart';
import 'signature_pad.dart';
import 'signature_processing.dart';

const inkColors = <int, String>{0xFF0B1F4D: 'Blue-black', 0xFF1A3FB8: 'Blue', 0xFF111111: 'Black', 0xFF8B1A1A: 'Red'};

/// Full-screen signature drawing. Returns transparent PNG bytes.
class DrawSignaturePage extends StatefulWidget {
  const DrawSignaturePage({super.key});

  @override
  State<DrawSignaturePage> createState() => _DrawSignaturePageState();
}

class _DrawSignaturePageState extends State<DrawSignaturePage> {
  final _strokes = SignatureStrokes();
  int _color = inkColors.keys.first;
  double _width = 3;

  @override
  void dispose() {
    _strokes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Draw signature'),
        actions: [
          AnimatedBuilder(
            animation: _strokes,
            builder: (context, _) => Row(
              children: [
                IconButton(
                  tooltip: 'Undo',
                  icon: const Icon(Icons.undo_rounded),
                  onPressed: _strokes.canUndo ? _strokes.undo : null,
                ),
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: _strokes.isEmpty ? null : _strokes.clear,
                ),
              ],
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gaps.page),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SignaturePad(strokes: _strokes, color: Color(_color), width: _width, height: double.infinity),
              ),
              const SizedBox(height: Gaps.l),
              Row(
                children: [
                  for (final e in inkColors.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: Gaps.m),
                      child: Semantics(
                        button: true,
                        selected: _color == e.key,
                        label: '${e.value} ink',
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _color = e.key),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Color(e.key),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _color == e.key ? Theme.of(context).colorScheme.primary : Colors.transparent,
                                width: 3,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              LabeledSlider(
                label: 'Pen thickness',
                value: _width,
                min: 1.5,
                max: 7,
                format: (v) => v.toStringAsFixed(1),
                onChanged: (v) => setState(() => _width = v),
              ),
              AnimatedBuilder(
                animation: _strokes,
                builder: (context, _) => FilledButton(
                  onPressed: _strokes.isEmpty
                      ? null
                      : () async {
                          final png = await _strokes.toPng(color: Color(_color), width: _width);
                          if (context.mounted) Navigator.pop(context, png);
                        },
                  child: const Text('Use signature'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Picks a saved signature, a new drawing or an imported image.
/// Returns the path of a private temporary PNG, or null.
Future<String?> pickSignature(BuildContext context, WidgetRef ref) async {
  final lib = ref.read(signatureLibraryProvider);
  final result = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _SignatureSheet(),
  );
  if (result == null || !context.mounted) return null;
  Uint8List? png;
  if (result == 'draw') {
    png = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(builder: (_) => const DrawSignaturePage()));
  } else if (result == 'import') {
    final picked = await pickInputs(context, ref, accept: Accept.image);
    if (picked.isEmpty) return null;
    png = await cleanSignature(
      await File(picked.first.path).readAsBytes(),
      const SignatureCleanup(inkArgb: 0xFF0B1F4D),
    );
  } else if (result is String) {
    return lib.toTempFile(result);
  }
  if (png == null || !context.mounted) return null;
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Save for next time?'),
      content: const Text('Saved signatures are encrypted and stay on this device.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Just this once')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
      ],
    ),
  );
  String id;
  if (save == true) {
    id = await lib.save(png);
    ref.invalidate(signatureListProvider);
    return lib.toTempFile(id);
  }
  final dir = await ref.read(workspaceProvider).newWorkDir();
  final path = '${dir.path}/signature.png';
  await File(path).writeAsBytes(png, flush: true);
  return path;
}

class _SignatureSheet extends ConsumerWidget {
  const _SignatureSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(signatureListProvider);
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gaps.page, 0, Gaps.page, Gaps.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Choose a signature', style: t.titleMedium),
            const SizedBox(height: Gaps.l),
            list.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(Gaps.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) =>
                  MessageBanner(kind: BannerKind.error, message: 'Saved signatures could not be loaded: $e'),
              data: (ids) => ids.isEmpty
                  ? Text('No saved signatures yet.', style: t.bodyMedium)
                  : SizedBox(
                      height: 96,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: ids.length,
                        separatorBuilder: (_, _) => const SizedBox(width: Gaps.m),
                        itemBuilder: (context, i) =>
                            SavedSignatureTile(id: ids[i], onTap: () => Navigator.pop(context, ids[i])),
                      ),
                    ),
            ),
            const SizedBox(height: Gaps.l),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, 'draw'),
              icon: const Icon(Icons.draw_outlined),
              label: const Text('Draw a new signature'),
            ),
            const SizedBox(height: Gaps.s),
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(context, 'import'),
              icon: const Icon(Icons.image_outlined),
              label: const Text('Import a photo of a signature'),
            ),
          ],
        ),
      ),
    );
  }
}

class SavedSignatureTile extends ConsumerWidget {
  const SavedSignatureTile({super.key, required this.id, required this.onTap, this.onLongPress});
  final String id;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.read(signatureLibraryProvider);
    return Semantics(
      button: true,
      label: 'Saved signature',
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(Radii.m),
        child: Container(
          width: 150,
          padding: const EdgeInsets.all(Gaps.s),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(Radii.m),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: FutureBuilder<Uint8List?>(
            future: lib.read(id),
            builder: (context, snap) => snap.data == null
                ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                : Image.memory(snap.data!, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}
