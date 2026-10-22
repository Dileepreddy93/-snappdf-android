import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import 'pdf_common.dart';

/// Lists the interactive (AcroForm) fields of a PDF as a native form.
class FillFormScreen extends ConsumerStatefulWidget {
  const FillFormScreen({super.key, this.initial = const []});
  final List<InputFile> initial;

  @override
  ConsumerState<FillFormScreen> createState() => _FillFormScreenState();
}

class _FillFormScreenState extends ConsumerState<FillFormScreen> with PdfInputs {
  List<PdfFormField>? _fields;
  bool _xfa = false;
  String? _loadError;
  final Map<String, Object?> _values = {};
  final Map<String, TextEditingController> _text = {};
  bool _flatten = false;

  @override
  void initState() {
    super.initState();
    initInputs(widget.initial);
  }

  @override
  void onInputsReady() => _load();

  Future<void> _load() async {
    final f = first;
    setState(() {
      _fields = null;
      _loadError = null;
      _values.clear();
      _text.clear();
    });
    if (f == null) return;
    try {
      final r = await api.formFields(f.path, password: f.password);
      if (!mounted) return;
      setState(() {
        _fields = r.fields;
        _xfa = r.xfa;
        for (final field in r.fields) {
          _values[field.name] = field.value;
          if (field.type == 'text') _text[field.name] = TextEditingController(text: '${field.value ?? ''}');
        }
      });
    } on NativeError catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    }
  }

  Map<String, Object?> _changes() {
    final out = <String, Object?>{};
    for (final f in _fields ?? const <PdfFormField>[]) {
      if (f.readOnly || f.type == 'signature') continue;
      final v = f.type == 'text' ? _text[f.name]!.text : _values[f.name];
      if (v != f.value && !(v == '' && f.value == null)) out[f.name] = v;
    }
    return out;
  }

  Widget _fieldWidget(PdfFormField f) {
    final label = f.label + (f.required ? ' *' : '');
    switch (f.type) {
      case 'text':
        return TextField(
          controller: _text[f.name],
          enabled: !f.readOnly,
          maxLines: f.multiline ? 4 : 1,
          maxLength: f.maxLength,
          decoration: InputDecoration(labelText: label),
          onChanged: (_) => setState(() {}),
        );
      case 'checkbox':
        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _values[f.name] == true,
          onChanged: f.readOnly ? null : (v) => setState(() => _values[f.name] = v ?? false),
          title: Text(label),
        );
      case 'radio':
      case 'combo':
        return DropdownButtonFormField<String>(
          initialValue: f.options.contains(_values[f.name]) ? _values[f.name] as String : null,
          decoration: InputDecoration(labelText: label),
          items: [for (final o in f.options) DropdownMenuItem(value: o, child: Text(o))],
          onChanged: f.readOnly ? null : (v) => setState(() => _values[f.name] = v),
        );
      case 'list':
        final selected = (_values[f.name] as List?)?.cast<String>() ?? const <String>[];
        return InputDecorator(
          decoration: InputDecoration(labelText: label),
          child: Wrap(
            spacing: Gaps.s,
            runSpacing: Gaps.s,
            children: [
              for (final o in f.options)
                FilterChip(
                  label: Text(o),
                  selected: selected.contains(o),
                  onSelected: f.readOnly
                      ? null
                      : (on) => setState(() {
                          final next = f.multiSelect ? [...selected] : <String>[];
                          on ? next.add(o) : next.remove(o);
                          _values[f.name] = next;
                        }),
                ),
            ],
          ),
        );
      case 'signature':
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.draw_outlined),
          title: Text(label),
          subtitle: const Text('Digital-signature field. Use “Sign PDF” to place a visual signature.'),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final fields = _fields;
    final byPage = <int?, List<PdfFormField>>{};
    for (final f in fields ?? const <PdfFormField>[]) {
      byPage.putIfAbsent(f.page, () => []).add(f);
    }
    return ToolScaffold(
      title: 'Fill form',
      about:
          'Fills the interactive form fields (AcroForm) of a PDF. Turn on “Flatten” to make the filled values '
          'permanent. Dynamic XFA forms (some government and Adobe LiveCycle forms) cannot be filled on this device; '
          'for scanned forms without fields, use “Edit PDF” to add text.',
      actionLabel: 'Save filled form',
      actionIcon: Icons.save_outlined,
      canRun: () {
        if (first == null) return 'Choose a PDF form';
        if (fields == null) return 'Loading fields…';
        if (fields.isEmpty) return 'This PDF has no fillable fields';
        if (_xfa) return 'Dynamic XFA forms are not supported';
        return null;
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pdfInputsCard(onChange: _load),
          const SizedBox(height: Gaps.xl),
          if (_loadError != null) MessageBanner(kind: BannerKind.error, message: _loadError!),
          if (first != null && fields == null && _loadError == null) const Center(child: CircularProgressIndicator()),
          if (_xfa)
            const MessageBanner(
              kind: BannerKind.warning,
              message: 'This is a dynamic XFA form. It cannot be filled here. Open it in Adobe Acrobat, or print it and fill by hand.',
            ),
          if (fields != null && fields.isEmpty && !_xfa)
            const MessageBanner(
              message: 'No fillable fields were found. If this is a scanned or printed form, use “Edit PDF” to type onto it.',
            ),
          for (final entry in byPage.entries) ...[
            Text(
              entry.key == null ? 'Fields' : 'Page ${entry.key! + 1}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: Gaps.m),
            for (final f in entry.value) ...[_fieldWidget(f), const SizedBox(height: Gaps.m)],
            const SizedBox(height: Gaps.m),
          ],
          if (fields != null && fields.isNotEmpty)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _flatten,
              onChanged: (v) => setState(() => _flatten = v),
              title: const Text('Flatten (make values permanent)'),
              subtitle: const Text('Fields can no longer be edited'),
            ),
        ],
      ),
      run: (context, job) async {
        final ws = ref.read(workspaceProvider);
        final f = first!;
        final changes = _changes();
        final name = derivedName(f.name, 'filled', extension: 'pdf');
        final out = await ws.newWorkFile(name);
        await withOwnerPassword(this, f, () => api.fillForm(f.path, f.password, out, changes, flatten: _flatten));
        final checks = [...await verifyPdf(api, out, expectedPages: firstInfo?.pageCount)];
        final after = await api.formFields(out);
        if (_flatten) {
          checks.add(Check('Fields flattened', after.fields.isEmpty));
        } else {
          final textChanges = changes.entries.where((e) => e.value is String).toList();
          final ok = textChanges.every(
            (e) => after.fields.any((x) => x.name == e.key && '${x.value ?? ''}' == e.value),
          );
          checks.add(Check('${changes.length} field${changes.length == 1 ? '' : 's'} saved', ok));
        }
        return ToolResult(
          headline: 'Form saved',
          outputs: [OutputFile(out, name)],
          checks: checks,
          notes: securityNotes(),
        );
      },
    );
  }
}

bool isPdf(InputFile f) => f.kind == FileKind.pdf;
