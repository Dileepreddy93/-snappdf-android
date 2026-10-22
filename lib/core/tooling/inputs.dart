import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../design/widgets.dart';
import '../files/file_kind.dart';
import '../files/library_store.dart';
import '../platform/native_api.dart';
import '../providers.dart';

/// A file selected as input for a tool. Inputs are private copies: the
/// user's original is never modified.
class InputFile {
  InputFile({required this.path, required this.name, required this.size, this.libraryId, this.password});

  final String path;
  final String name;
  final int size;
  final String? libraryId;
  String? password;

  FileKind get kind => FileKind.ofName(name);

  factory InputFile.fromPicked(PickedFile f) => InputFile(path: f.path, name: f.name, size: f.size);

  factory InputFile.fromEntry(LibraryStore store, LibraryEntry e) =>
      InputFile(path: store.fileOf(e).path, name: e.name, size: e.size, libraryId: e.id);
}

enum Accept {
  pdf(['application/pdf'], 'PDF'),
  image(['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/bmp', 'image/heic', 'image/heif'], 'image'),
  pdfOrImage(['application/pdf', 'image/jpeg', 'image/png', 'image/webp'], 'PDF or image'),
  text(['text/plain'], 'text file');

  const Accept(this.mimes, this.label);
  final List<String> mimes;
  final String label;

  bool accepts(FileKind kind) => switch (this) {
    Accept.pdf => kind == FileKind.pdf,
    Accept.image => kind == FileKind.image,
    Accept.pdfOrImage => kind == FileKind.pdf || kind == FileKind.image,
    Accept.text => kind == FileKind.text,
  };
}

/// Shows the source chooser and returns the selected inputs (empty if cancelled).
Future<List<InputFile>> pickInputs(
  BuildContext context,
  WidgetRef ref, {
  required Accept accept,
  bool multiple = false,
}) async {
  final api = ref.read(nativeApiProvider);
  final library = ref.read(libraryStoreProvider);
  final hasLibraryFiles = library.active.any((e) => accept.accepts(e.kind));
  final canCamera = accept == Accept.image || accept == Accept.pdfOrImage;

  final source = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gaps.page, 0, Gaps.page, Gaps.s),
            child: Text(
              multiple ? 'Add ${accept.label} files' : 'Choose a ${accept.label}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('Browse device'),
            subtitle: const Text('Downloads, Drive and other storage'),
            onTap: () => Navigator.pop(context, 'device'),
          ),
          if (hasLibraryFiles)
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('SnapPDF files'),
              subtitle: const Text('Files you created or opened here'),
              onTap: () => Navigator.pop(context, 'library'),
            ),
          if (canCamera)
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
          const SizedBox(height: Gaps.s),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return const [];

  try {
    switch (source) {
      case 'device':
        final picked = await api.pickFiles(accept.mimes, multiple: multiple);
        final ok = picked.where((f) => accept.accepts(FileKind.ofName(f.name))).toList();
        if (ok.length < picked.length && context.mounted) {
          showMessage(context, '${picked.length - ok.length} file(s) skipped: not a ${accept.label}.');
        }
        return ok.map(InputFile.fromPicked).toList();
      case 'library':
        final entries = await Navigator.of(context).push<List<LibraryEntry>>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => LibraryPickerPage(accept: accept, multiple: multiple),
          ),
        );
        return [for (final e in entries ?? const <LibraryEntry>[]) InputFile.fromEntry(library, e)];
      case 'camera':
        final path = await api.takePhoto();
        if (path == null) return const [];
        final f = File(path);
        return [InputFile(path: path, name: 'Photo ${_stamp()}.jpg', size: await f.length())];
    }
  } on NativeError catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
  return const [];
}

String _stamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
}

/// Selects files from the private library.
class LibraryPickerPage extends ConsumerStatefulWidget {
  const LibraryPickerPage({super.key, required this.accept, required this.multiple});
  final Accept accept;
  final bool multiple;

  @override
  ConsumerState<LibraryPickerPage> createState() => _LibraryPickerPageState();
}

class _LibraryPickerPageState extends ConsumerState<LibraryPickerPage> {
  final _selected = <String>{};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    ref.watch(libraryProvider);
    final store = ref.read(libraryStoreProvider);
    final items = store.query(text: _query).where((e) => widget.accept.accepts(e.kind)).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.multiple ? 'Select files' : 'Select a file'),
        actions: [
          if (widget.multiple)
            TextButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, [
                      for (final id in _selected)
                        if (store.byId(id) != null) store.byId(id)!,
                    ]),
              child: Text(_selected.isEmpty ? 'Add' : 'Add ${_selected.length}'),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gaps.page, 0, Gaps.page, Gaps.s),
            child: SearchBar(
              hintText: 'Search files',
              leading: const Icon(Icons.search_rounded),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const EmptyState(icon: Icons.inventory_2_outlined, title: 'No matching files')
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final e = items[i];
                      final selected = _selected.contains(e.id);
                      return ListTile(
                        leading: FileThumb(name: e.name, path: store.fileOf(e).path, size: 44),
                        title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(formatBytes(e.size)),
                        trailing: widget.multiple
                            ? Checkbox(
                                value: selected,
                                onChanged: (_) =>
                                    setState(() => selected ? _selected.remove(e.id) : _selected.add(e.id)),
                              )
                            : null,
                        onTap: () {
                          if (!widget.multiple) {
                            Navigator.pop(context, [e]);
                          } else {
                            setState(() => selected ? _selected.remove(e.id) : _selected.add(e.id));
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Asks for a PDF password. Returns null if the user cancels.
Future<String?> askPassword(BuildContext context, String fileName, {bool wrong = false, bool owner = false}) {
  final controller = TextEditingController();
  var obscure = true;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(owner ? 'Owner password needed' : 'Password protected'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              owner
                  ? '“$fileName” restricts changes. Enter the owner password to continue.'
                  : '“$fileName” needs a password to open.',
            ),
            const SizedBox(height: Gaps.l),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Password',
                errorText: wrong ? 'Incorrect password. Try again.' : null,
                suffixIcon: IconButton(
                  tooltip: obscure ? 'Show password' : 'Hide password',
                  icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => obscure = !obscure),
                ),
              ),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Unlock')),
        ],
      ),
    ),
  );
}

/// Opens [input] (prompting for a password if needed) and returns its info,
/// or null if the user cancelled the password prompt.
Future<PdfInfo?> probePdf(BuildContext context, NativeApi api, InputFile input) async {
  var wrong = false;
  while (true) {
    try {
      return await api.pdfInfo(input.path, password: input.password);
    } on NativeError catch (e) {
      if (e.code == NativeError.passwordRequired || e.code == NativeError.wrongPassword) {
        if (!context.mounted) return null;
        final pw = await askPassword(
          context,
          input.name,
          wrong: wrong || e.code == NativeError.wrongPassword && input.password != null,
        );
        if (pw == null) return null;
        input.password = pw;
        wrong = true;
        continue;
      }
      rethrow;
    }
  }
}

/// Runs [op]; when it fails because the owner restricts changes, asks for the
/// owner password (on [host]'s context) and retries.
Future<T> withOwnerPassword<T>(State host, InputFile input, Future<T> Function() op) async {
  var attempts = 0;
  while (true) {
    try {
      return await op();
    } on NativeError catch (e) {
      if (e.code != NativeError.restricted || attempts > 3 || !host.mounted) rethrow;
      final pw = await askPassword(host.context, input.name, owner: true, wrong: attempts > 0);
      if (pw == null) throw NativeError(NativeError.cancelled, 'Cancelled.');
      input.password = pw;
      attempts++;
    }
  }
}
