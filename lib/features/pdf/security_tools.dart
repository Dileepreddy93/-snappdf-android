import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import 'pdf_common.dart';

class ProtectPdfScreen extends ConsumerStatefulWidget {
  const ProtectPdfScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<ProtectPdfScreen> createState() => _ProtectPdfScreenState();
}

class _ProtectPdfScreenState extends ConsumerState<ProtectPdfScreen> with PdfInputs {
  final _pw = TextEditingController();
  final _confirm = TextEditingController();
  final _owner = TextEditingController();
  bool _obscure = true;
  bool _restrict = false;
  bool _print = true, _copy = false, _modify = false;

  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  String? _strength(String pw) {
    if (pw.isEmpty) return null;
    var score = 0;
    if (pw.length >= 8) score++;
    if (pw.length >= 12) score++;
    if (RegExp(r'[A-Z]').hasMatch(pw) && RegExp(r'[a-z]').hasMatch(pw)) score++;
    if (RegExp(r'\d').hasMatch(pw)) score++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(pw)) score++;
    return score <= 1
        ? 'Weak'
        : score <= 3
        ? 'Fair'
        : 'Strong';
  }

  @override
  Widget build(BuildContext context) {
    final strength = _strength(_pw.text);
    final changing = firstInfo?.encrypted ?? false;
    return ToolScaffold(
      title: changing ? 'Change password' : 'Protect PDF',
      about:
          'Encrypts the PDF with AES-256, the strongest standard PDF encryption. Anyone opening the '
          'file needs the password. Permission restrictions (printing, copying, editing) are honoured by '
          'most PDF apps but cannot be technically enforced against all software. SnapPDF cannot recover '
          'a forgotten password.',
      actionLabel: changing ? 'Change password' : 'Protect',
      actionIcon: Icons.lock_outline_rounded,
      canRun: () {
        if (first == null) return 'Choose a PDF';
        if (_pw.text.isEmpty) return 'Enter a password';
        if (_pw.text != _confirm.text) return 'Passwords do not match';
        if (_restrict && _owner.text.isNotEmpty && _owner.text == _pw.text) {
          return 'The owner password must differ from the open password';
        }
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(),
          const SizedBox(height: Gaps.xl),
          OptionGroup(
            title: 'Password to open',
            children: [
              TextField(
                controller: _pw,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: strength == null ? null : 'Strength: $strength',
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Show password' : 'Hide password',
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Gaps.m),
              TextField(
                controller: _confirm,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Confirm password',
                  errorText: _confirm.text.isNotEmpty && _confirm.text != _pw.text ? 'Passwords do not match' : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _restrict,
            onChanged: (v) => setState(() => _restrict = v),
            title: const Text('Restrict printing, copying and editing'),
          ),
          if (_restrict) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _print,
              onChanged: (v) => setState(() => _print = v!),
              title: const Text('Allow printing'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _copy,
              onChanged: (v) => setState(() => _copy = v!),
              title: const Text('Allow copying text and images'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _modify,
              onChanged: (v) => setState(() => _modify = v!),
              title: const Text('Allow editing'),
            ),
            const SizedBox(height: Gaps.s),
            TextField(
              controller: _owner,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Owner password (optional)',
                helperText: 'Needed to lift restrictions later. Leave empty to lock them permanently.',
                helperMaxLines: 2,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final f = first!;
        final name = derivedName(f.name, 'protected', extension: 'pdf');
        final out = await ws.newWorkFile(name);
        await withOwnerPassword(
          this,
          f,
          () => api.protect({
            'path': f.path,
            'password': f.password,
            'output': out,
            'userPassword': _pw.text,
            'ownerPassword': _restrict && _owner.text.isNotEmpty ? _owner.text : null,
            'permissions': _restrict
                ? {'print': _print, 'copy': _copy, 'modify': _modify, 'annotate': _modify, 'fillForms': _modify}
                : null,
          }),
        );
        final checks = <Check>[];
        try {
          await api.pdfInfo(out);
          checks.add(const Check('Opening without a password is blocked', false));
        } on NativeError catch (e) {
          checks.add(Check('Opening without a password is blocked', e.code == NativeError.passwordRequired));
        }
        try {
          final info = await api.pdfInfo(out, password: _pw.text);
          checks.add(Check('Opens with your password (${pages(info.pageCount)})', info.encrypted));
        } on NativeError {
          checks.add(const Check('Opens with your password', false));
        }
        return ToolResult(
          headline: 'PDF protected with AES-256',
          outputs: [OutputFile(out, name)],
          checks: checks,
          notes: const ['Keep your password safe. It cannot be recovered if you forget it.'],
        );
      },
    );
  }
}

class UnlockPdfScreen extends ConsumerStatefulWidget {
  const UnlockPdfScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<UnlockPdfScreen> createState() => _UnlockPdfScreenState();
}

class _UnlockPdfScreenState extends ConsumerState<UnlockPdfScreen> with PdfInputs {
  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    final info = firstInfo;
    return ToolScaffold(
      title: 'Remove password',
      about:
          'Creates an unprotected copy of a PDF you can open. You must know the password. If the '
          'owner has restricted changes, the owner password is required as well.',
      actionLabel: 'Remove password',
      actionIcon: Icons.lock_open_rounded,
      canRun: () {
        if (first == null) return 'Choose a protected PDF';
        if (info != null && !info.encrypted) return 'This PDF is not password protected';
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(emptyLabel: 'Choose a protected PDF'),
          if (info != null && !info.encrypted) ...[
            const SizedBox(height: Gaps.l),
            const MessageBanner(message: 'This PDF has no password, so there is nothing to remove.'),
          ],
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final f = first!;
        final name = derivedName(f.name, 'unlocked', extension: 'pdf');
        final out = await ws.newWorkFile(name);
        await withOwnerPassword(this, f, () => api.unlock(f.path, f.password, out));
        final checks = <Check>[];
        try {
          final i = await api.pdfInfo(out);
          checks.add(Check('Opens without a password', !i.encrypted));
          checks.add(Check('${pages(i.pageCount)} kept', i.pageCount == info?.pageCount));
        } on NativeError catch (e) {
          checks.add(Check('Output check failed: ${e.message}', false));
        }
        return ToolResult(headline: 'Password removed', outputs: [OutputFile(out, name)], checks: checks);
      },
    );
  }
}

class PdfMetadataScreen extends ConsumerStatefulWidget {
  const PdfMetadataScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<PdfMetadataScreen> createState() => _PdfMetadataScreenState();
}

class _PdfMetadataScreenState extends ConsumerState<PdfMetadataScreen> with PdfInputs {
  final _title = TextEditingController();
  final _author = TextEditingController();
  final _subject = TextEditingController();
  final _keywords = TextEditingController();
  bool _removeAll = true;

  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  @override
  void onInputsReady() => _fill();

  void _fill() {
    final m = firstInfo?.metadata;
    _title.text = m?.title ?? '';
    _author.text = m?.author ?? '';
    _subject.text = m?.subject ?? '';
    _keywords.text = m?.keywords ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final m = firstInfo?.metadata;
    final df = DateFormat.yMMMd().add_jm();
    return ToolScaffold(
      title: 'PDF metadata',
      about:
          'Shows the hidden document properties stored in a PDF (title, author, software, dates) '
          'and lets you edit them or remove them all, including XMP metadata, page thumbnails and the '
          'document identifier.',
      actionLabel: _removeAll ? 'Remove metadata' : 'Save changes',
      actionIcon: _removeAll ? Icons.cleaning_services_outlined : Icons.save_outlined,
      canRun: () => first == null ? 'Choose a PDF' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(onChange: _fill),
          if (m != null) ...[
            const SizedBox(height: Gaps.xl),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Gaps.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Current properties', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: Gaps.s),
                    if (m.isEmpty) const Text('No metadata found.'),
                    if (m.title?.isNotEmpty ?? false) InfoRow('Title', m.title!),
                    if (m.author?.isNotEmpty ?? false) InfoRow('Author', m.author!),
                    if (m.subject?.isNotEmpty ?? false) InfoRow('Subject', m.subject!),
                    if (m.keywords?.isNotEmpty ?? false) InfoRow('Keywords', m.keywords!),
                    if (m.creator?.isNotEmpty ?? false) InfoRow('Created with', m.creator!),
                    if (m.producer?.isNotEmpty ?? false) InfoRow('Producer', m.producer!),
                    if (m.created != null) InfoRow('Created', df.format(m.created!)),
                    if (m.modified != null) InfoRow('Modified', df.format(m.modified!)),
                    if (m.hasXmp) const InfoRow('XMP', 'Present'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Gaps.l),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Remove all'), icon: Icon(Icons.cleaning_services_outlined)),
                ButtonSegment(value: false, label: Text('Edit'), icon: Icon(Icons.edit_outlined)),
              ],
              selected: {_removeAll},
              onSelectionChanged: (v) => setState(() => _removeAll = v.first),
            ),
            if (!_removeAll) ...[
              const SizedBox(height: Gaps.l),
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: Gaps.m),
              TextField(
                controller: _author,
                decoration: const InputDecoration(labelText: 'Author'),
              ),
              const SizedBox(height: Gaps.m),
              TextField(
                controller: _subject,
                decoration: const InputDecoration(labelText: 'Subject'),
              ),
              const SizedBox(height: Gaps.m),
              TextField(
                controller: _keywords,
                decoration: const InputDecoration(labelText: 'Keywords'),
              ),
            ],
          ],
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final f = first!;
        final name = derivedName(f.name, _removeAll ? 'clean' : 'edited', extension: 'pdf');
        final out = await ws.newWorkFile(name);
        await withOwnerPassword(
          this,
          f,
          () => api.setMetadata(
            f.path,
            f.password,
            out,
            removeAll: _removeAll,
            metadata: _removeAll
                ? null
                : PdfMetadata(
                    title: _title.text,
                    author: _author.text,
                    subject: _subject.text,
                    keywords: _keywords.text,
                    creator: firstInfo?.metadata.creator,
                    producer: 'SnapPDF',
                  ),
          ),
        );
        final i = await api.pdfInfo(out);
        final checks = <Check>[
          Check('${pages(i.pageCount)} kept', i.pageCount == firstInfo?.pageCount),
          if (_removeAll)
            Check(
              'No author, title or XMP metadata remains',
              (i.metadata.author ?? '').isEmpty && (i.metadata.title ?? '').isEmpty && !i.metadata.hasXmp,
            )
          else
            Check('Title is “${i.metadata.title ?? ''}”', (i.metadata.title ?? '') == _title.text.trim()),
        ];
        return ToolResult(
          headline: _removeAll ? 'Metadata removed' : 'Metadata updated',
          outputs: [OutputFile(out, name)],
          checks: checks,
          notes: securityNotes(),
        );
      },
    );
  }
}

class WatermarkPdfScreen extends ConsumerStatefulWidget {
  const WatermarkPdfScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<WatermarkPdfScreen> createState() => _WatermarkPdfScreenState();
}

class _WatermarkPdfScreenState extends ConsumerState<WatermarkPdfScreen> with PdfInputs {
  final _text = TextEditingController(text: 'CONFIDENTIAL');
  double _size = 48;
  double _opacity = 0.25;
  double _rotation = 45;
  bool _tile = false;
  int _color = 0xFFC62828;
  InputFile? _image;
  bool _useImage = false;

  static const _colors = [0xFFC62828, 0xFF1565C0, 0xFF2E7D32, 0xFF424242, 0xFF6A1B9A];

  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      title: 'Add watermark',
      about:
          'Stamps text or an image onto every page. The watermark becomes part of the page content. '
          'It deters casual copying but can be removed by determined users with editing software.',
      actionLabel: 'Add watermark',
      actionIcon: Icons.water_drop_outlined,
      canRun: () {
        if (first == null) return 'Choose a PDF';
        if (_useImage && _image == null) return 'Choose a watermark image';
        if (!_useImage && _text.text.trim().isEmpty) return 'Enter watermark text';
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(),
          const SizedBox(height: Gaps.xl),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Text'), icon: Icon(Icons.text_fields_rounded)),
              ButtonSegment(value: true, label: Text('Image'), icon: Icon(Icons.image_outlined)),
            ],
            selected: {_useImage},
            onSelectionChanged: (v) => setState(() => _useImage = v.first),
          ),
          const SizedBox(height: Gaps.l),
          if (!_useImage) ...[
            TextField(
              controller: _text,
              decoration: const InputDecoration(labelText: 'Watermark text'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Gaps.l),
            LabeledSlider(
              label: 'Text size',
              value: _size,
              min: 12,
              max: 120,
              onChanged: (v) => setState(() => _size = v),
            ),
            const SizedBox(height: Gaps.s),
            Text('Colour', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: Gaps.s),
            Wrap(
              spacing: Gaps.m,
              children: [
                for (final c in _colors)
                  Semantics(
                    button: true,
                    selected: c == _color,
                    label: 'Colour',
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _color = c),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Color(c),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c == _color ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ] else
            InputsCard(
              inputs: [?_image],
              accept: Accept.image,
              emptyLabel: 'Choose a watermark image (PNG with transparency works best)',
              onChanged: (l) => setState(() => _image = l.isEmpty ? null : l.first),
            ),
          const SizedBox(height: Gaps.l),
          LabeledSlider(
            label: 'Opacity',
            value: _opacity,
            min: 0.05,
            max: 1,
            format: (v) => '${(v * 100).round()}%',
            onChanged: (v) => setState(() => _opacity = v),
          ),
          LabeledSlider(
            label: 'Angle',
            value: _rotation,
            min: -90,
            max: 90,
            divisions: 12,
            format: (v) => '${v.round()}°',
            onChanged: (v) => setState(() => _rotation = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _tile,
            onChanged: (v) => setState(() => _tile = v),
            title: const Text('Repeat across the page'),
          ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final f = first!;
        final name = derivedName(f.name, 'watermarked', extension: 'pdf');
        final out = await ws.newWorkFile(name);
        await withOwnerPassword(
          this,
          f,
          () => api.watermark({
            'path': f.path,
            'password': f.password,
            'output': out,
            'text': _useImage ? null : _text.text.trim(),
            'imagePath': _useImage ? _image!.path : null,
            'fontSize': _size,
            'color': _color,
            'opacity': _opacity,
            // UI angle is counter-clockwise positive; engine rotates clockwise.
            'rotation': -_rotation,
            'layout': _tile ? 'tile' : 'center',
            'jobId': job.id,
          }),
        );
        return ToolResult(
          headline: 'Watermark added',
          outputs: [OutputFile(out, name)],
          checks: await verifyPdf(api, out, expectedPages: firstInfo?.pageCount),
          notes: securityNotes(),
          detail: (saved) => PdfBeforeAfter(before: f.path, beforePassword: f.password, after: saved.first),
        );
      },
    );
  }
}

class PageNumbersScreen extends ConsumerStatefulWidget {
  const PageNumbersScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<PageNumbersScreen> createState() => _PageNumbersScreenState();
}

class _PageNumbersScreenState extends ConsumerState<PageNumbersScreen> with PdfInputs {
  String _format = 'Page {n} of {total}';
  String _position = 'bottom-center';
  final _start = TextEditingController(text: '1');
  final _header = TextEditingController();
  final _footer = TextEditingController();
  bool _skipFirst = false;
  double _size = 10;

  static const _formats = ['{n}', 'Page {n}', 'Page {n} of {total}', '{n} / {total}', ''];
  static const _positions = {
    'bottom-center': 'Bottom centre',
    'bottom-right': 'Bottom right',
    'bottom-left': 'Bottom left',
    'top-center': 'Top centre',
    'top-right': 'Top right',
    'top-left': 'Top left',
  };

  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      title: 'Page numbers & headers',
      about: 'Adds page numbers, a header and/or a footer to each page, upright even on rotated pages.',
      actionLabel: 'Apply',
      actionIcon: Icons.format_list_numbered_rounded,
      canRun: () {
        if (first == null) return 'Choose a PDF';
        if (_format.isEmpty && _header.text.trim().isEmpty && _footer.text.trim().isEmpty) {
          return 'Choose a number format or enter a header/footer';
        }
        if (int.tryParse(_start.text) == null) return 'Enter a valid start number';
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(),
          const SizedBox(height: Gaps.xl),
          OptionGroup(
            title: 'Number format',
            children: [
              Wrap(
                spacing: Gaps.s,
                runSpacing: Gaps.s,
                children: [
                  for (final f in _formats)
                    ChoiceChip(
                      label: Text(f.isEmpty ? 'No numbers' : f.replaceAll('{n}', '3').replaceAll('{total}', '12')),
                      selected: _format == f,
                      onSelected: (_) => setState(() => _format = f),
                    ),
                ],
              ),
            ],
          ),
          if (_format.isNotEmpty)
            OptionGroup(
              title: 'Position',
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _position,
                  items: [for (final e in _positions.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) => setState(() => _position = v!),
                ),
                const SizedBox(height: Gaps.m),
                TextField(
                  controller: _start,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Start at'),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          OptionGroup(
            title: 'Header and footer',
            children: [
              TextField(
                controller: _header,
                decoration: const InputDecoration(labelText: 'Header (optional)'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Gaps.m),
              TextField(
                controller: _footer,
                decoration: const InputDecoration(labelText: 'Footer (optional)'),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          LabeledSlider(label: 'Text size', value: _size, min: 6, max: 24, onChanged: (v) => setState(() => _size = v)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _skipFirst,
            onChanged: (v) => setState(() => _skipFirst = v),
            title: const Text('Skip the first page'),
            subtitle: const Text('For cover pages'),
          ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final f = first!;
        final name = derivedName(f.name, 'numbered', extension: 'pdf');
        final out = await ws.newWorkFile(name);
        await withOwnerPassword(
          this,
          f,
          () => api.pageNumbers({
            'path': f.path,
            'password': f.password,
            'output': out,
            'format': _format,
            'position': _position,
            'fontSize': _size,
            'startAt': int.parse(_start.text),
            'skipFirst': _skipFirst,
            'header': _header.text.trim(),
            'footer': _footer.text.trim(),
            'jobId': job.id,
          }),
        );
        return ToolResult(
          headline: 'Page numbers added',
          outputs: [OutputFile(out, name)],
          checks: await verifyPdf(api, out, expectedPages: firstInfo?.pageCount),
          notes: securityNotes(),
          detail: (saved) => PdfBeforeAfter(before: f.path, beforePassword: f.password, after: saved.first),
        );
      },
    );
  }
}

class FlattenPdfScreen extends ConsumerStatefulWidget {
  const FlattenPdfScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<FlattenPdfScreen> createState() => _FlattenPdfScreenState();
}

class _FlattenPdfScreenState extends ConsumerState<FlattenPdfScreen> with PdfInputs {
  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  @override
  Widget build(BuildContext context) => ToolScaffold(
    title: 'Flatten PDF',
    about:
        'Merges form fields, comments, highlights and drawings into the page content so they '
        'can no longer be edited, moved or hidden. Links are kept. Useful before sending a filled '
        'form or annotated document.',
    actionLabel: 'Flatten',
    actionIcon: Icons.layers_clear_outlined,
    canRun: () => first == null ? 'Choose a PDF' : null,
    body: pdfInputsCard(),
    run: (context, job) async {
      final ws = ref.read(workspaceProvider);
      final f = first!;
      final name = derivedName(f.name, 'flattened', extension: 'pdf');
      final out = await ws.newWorkFile(name);
      final r = await withOwnerPassword(this, f, () => api.flatten(f.path, f.password, out, jobId: job.id));
      final fields = await api.formFields(out);
      return ToolResult(
        headline: r.annotations + r.fields == 0
            ? 'Nothing to flatten'
            : 'Flattened ${r.annotations} annotation${r.annotations == 1 ? '' : 's'} and ${r.fields} field${r.fields == 1 ? '' : 's'}',
        outputs: [OutputFile(out, name)],
        checks: [
          ...await verifyPdf(api, out, expectedPages: firstInfo?.pageCount),
          Check('No editable form fields remain', fields.fields.isEmpty),
        ],
        notes: securityNotes(),
      );
    },
  );
}

String fileSummary(InputFile f) => '${f.name} · ${formatBytes(f.size)}';
