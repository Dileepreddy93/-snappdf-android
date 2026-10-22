import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import '../image/engine/image_engine.dart';
import '../image/engine/image_format.dart';
import '../image/image_tools.dart';
import 'signature_library.dart';
import 'signature_picker.dart';
import 'signature_processing.dart';

/// Create, clean, resize and export signatures; manage the private library.
class SignatureStudioScreen extends ConsumerStatefulWidget {
  const SignatureStudioScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<SignatureStudioScreen> createState() => _SignatureStudioScreenState();
}

class _SignatureStudioScreenState extends ConsumerState<SignatureStudioScreen> {
  Uint8List? _source; // imported photo bytes (for re-cleaning)
  Uint8List? _png; // current transparent signature
  double _threshold = 150;
  int _ink = inkColors.keys.first;
  bool _recolor = true;
  bool _exact = false;
  final _w = TextEditingController(text: '300');
  final _h = TextEditingController(text: '80');
  bool _transparent = true;
  bool _limit = false;
  final _kb = TextEditingController(text: '20');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final img = widget.initial.where((f) => f.kind == FileKind.image).firstOrNull;
    if (img != null) WidgetsBinding.instance.addPostFrameCallback((_) => _import(img));
  }

  Future<void> _import(InputFile f) async {
    final bytes = await File(f.path).readAsBytes();
    _source = bytes;
    await _reclean();
  }

  Future<void> _reclean() async {
    if (_source == null) return;
    setState(() => _busy = true);
    try {
      final png = await cleanSignature(
        _source!,
        SignatureCleanup(threshold: _threshold.round(), inkArgb: _recolor ? _ink : null),
      );
      if (mounted) setState(() => _png = png);
    } catch (e) {
      if (mounted) showMessage(context, 'Could not process this image: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _draw() async {
    final png = await Navigator.of(context)
        .push<Uint8List>(MaterialPageRoute(builder: (_) => const DrawSignaturePage()));
    if (png != null) {
      setState(() {
        _png = png;
        _source = null;
      });
    }
  }

  Future<void> _setInk(int c) async {
    setState(() => _ink = c);
    if (_source != null) {
      await _reclean();
    } else if (_png != null) {
      final out = await recolorSignature(_png!, c);
      if (mounted) setState(() => _png = out);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final saved = ref.watch(signatureListProvider);
    return ToolScaffold(
      title: 'Signature studio',
      about:
          'Draw or import your signature, clean the background, choose the ink colour and export it at an exact '
          'size and file-size limit for online applications. Saved signatures are encrypted on this device and never uploaded. '
          'A signature image is not a cryptographic digital signature.',
      actionLabel: 'Export signature',
      actionIcon: Icons.ios_share_rounded,
      canRun: () {
        if (_png == null) return 'Draw or import a signature';
        if (_exact && (int.tryParse(_w.text) ?? 0) <= 0) return 'Enter the width';
        if (_exact && (int.tryParse(_h.text) ?? 0) <= 0) return 'Enter the height';
        if (_limit && SizeLimitField.bytes(_kb.text, false) == null) return 'Enter the size limit';
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('My signatures', style: t.titleSmall),
          const SizedBox(height: Gaps.s),
          saved.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => MessageBanner(kind: BannerKind.error, message: '$e'),
            data: (ids) => ids.isEmpty
                ? Text('None saved yet.', style: t.bodySmall)
                : SizedBox(
                    height: 88,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: ids.length,
                      separatorBuilder: (_, _) => const SizedBox(width: Gaps.m),
                      itemBuilder: (context, i) => SavedSignatureTile(
                        id: ids[i],
                        onTap: () async {
                          final bytes = await ref.read(signatureLibraryProvider).read(ids[i]);
                          if (bytes != null && mounted) {
                            setState(() {
                              _png = bytes;
                              _source = null;
                            });
                          }
                        },
                        onLongPress: () async {
                          final del = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Delete this signature?'),
                              content: const Text('It will be permanently removed from this device.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );
                          if (del == true) {
                            await ref.read(signatureLibraryProvider).delete(ids[i]);
                            ref.invalidate(signatureListProvider);
                          }
                        },
                      ),
                    ),
                  ),
          ),
          if ((saved.value ?? const []).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Tap to use · long-press to delete', style: t.bodySmall),
            ),
          const SizedBox(height: Gaps.xl),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _draw,
                  icon: const Icon(Icons.draw_outlined),
                  label: const Text('Draw'),
                ),
              ),
              const SizedBox(width: Gaps.m),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await pickInputs(context, ref, accept: Accept.image);
                    if (picked.isNotEmpty) await _import(picked.first);
                  },
                  icon: const Icon(Icons.photo_outlined),
                  label: const Text('Import photo'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gaps.l),
          Container(
            height: 160,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(Radii.m),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
            padding: const EdgeInsets.all(Gaps.m),
            child: _busy
                ? const Center(child: CircularProgressIndicator())
                : _png == null
                ? Center(
                    child: Text('Your signature appears here', style: t.bodyMedium!.copyWith(color: Colors.black45)),
                  )
                : Image.memory(_png!, fit: BoxFit.contain),
          ),
          if (_png != null) ...[
            const SizedBox(height: Gaps.s),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  await ref.read(signatureLibraryProvider).save(_png!);
                  ref.invalidate(signatureListProvider);
                  if (context.mounted) showMessage(context, 'Saved to My signatures (encrypted on this device)');
                },
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Save to My signatures'),
              ),
            ),
            const SizedBox(height: Gaps.l),
            OptionGroup(
              title: 'Ink colour',
              children: [
                Row(
                  children: [
                    for (final e in inkColors.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: Gaps.m),
                        child: Semantics(
                          button: true,
                          selected: _ink == e.key,
                          label: '${e.value} ink',
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => _setInk(e.key),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Color(e.key),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _ink == e.key ? Theme.of(context).colorScheme.primary : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                if (_source != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _recolor,
                    onChanged: (v) {
                      setState(() => _recolor = v);
                      _reclean();
                    },
                    title: const Text('Replace ink colour'),
                  ),
              ],
            ),
            if (_source != null)
              LabeledSlider(
                label: 'Background removal',
                value: _threshold,
                min: 60,
                max: 230,
                format: (v) => v.round().toString(),
                onChanged: (v) => setState(() => _threshold = v),
              ),
            if (_source != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: _reclean, child: const Text('Apply')),
              ),
            OptionGroup(
              title: 'Export',
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _transparent,
                  onChanged: (v) => setState(() => _transparent = v),
                  title: const Text('Transparent background (PNG)'),
                  subtitle: const Text('Turn off for a white-background JPG, often required by application portals'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _exact,
                  onChanged: (v) => setState(() => _exact = v),
                  title: const Text('Exact pixel size'),
                ),
                if (_exact)
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
                      const SizedBox(width: Gaps.m),
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
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _limit,
                  onChanged: (v) => setState(() => _limit = v),
                  title: const Text('Maximum file size'),
                ),
                if (_limit)
                  TextField(
                    controller: _kb,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Maximum size (KB)'),
                    onChanged: (_) => setState(() {}),
                  ),
              ],
            ),
          ],
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final format = _transparent ? ImgFormat.png : ImgFormat.jpeg;
        final w = int.tryParse(_w.text), h = int.tryParse(_h.text);
        final r = await processImage(
          _png!,
          ImageSpec(
            format: format,
            quality: 92,
            resize: _exact ? ResizeSpec(width: w, height: h, mode: ResizeMode.pad, allowUpscale: true) : null,
            targetBytes: _limit ? SizeLimitField.bytes(_kb.text, false) : null,
            background: 0xFFFFFFFF,
          ),
        );
        final name = 'Signature_${r.width}x${r.height}.${format.extension}';
        final out = await ws.newWorkFile(name);
        await File(out).writeAsBytes(r.bytes, flush: true);
        return ToolResult(
          headline: 'Signature exported',
          outputs: [OutputFile(out, name)],
          checks: [
            if (_exact) Check('Exactly $w × $h px (got ${r.width} × ${r.height})', r.width == w && r.height == h),
            if (_limit) Check('At most ${_kb.text} KB (got ${formatBytes(r.bytes.length)})', r.targetMet),
            if (_transparent) const Check('Transparent background', true),
          ],
          notes: r.notes,
        );
      },
    );
  }
}
