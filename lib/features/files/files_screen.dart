import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/files/library_store.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import 'file_tile.dart';

enum _Filter { all, pdf, image, favorites, trash }

class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  _Filter _filter = _Filter.all;
  LibrarySort _sort = LibrarySort.recent;
  String _query = '';
  String? _folder;
  final Set<String> _selected = {};
  bool _searching = false;

  bool get _selecting => _selected.isNotEmpty;

  Future<void> _import() async {
    final picked = await pickInputs(context, ref, accept: Accept.pdfOrImage, multiple: true);
    var dup = 0;
    for (final f in picked.where((f) => f.libraryId == null)) {
      final r = await ref.read(libraryProvider.notifier).addImported(f.path, f.name);
      if (r.duplicateOf != null) dup++;
    }
    if (mounted && picked.isNotEmpty) {
      showMessage(context, 'Added ${picked.length} file(s)${dup > 0 ? ' · $dup already in your files' : ''}');
    }
  }

  Future<void> _bulk(String action) async {
    final lib = ref.read(libraryProvider.notifier);
    final store = ref.read(libraryStoreProvider);
    final ids = _selected.toList();
    final entries = [
      for (final id in ids)
        if (store.byId(id) != null) store.byId(id)!,
    ];
    try {
      switch (action) {
        case 'share':
          await ref.read(nativeApiProvider).share([for (final e in entries) store.fileOf(e).path], '*/*');
        case 'export':
          await exportEntries(context, ref, entries);
        case 'move':
          final folder = await pickFolderName(context, store.folders);
          if (folder == null) return;
          await lib.mutate((s) => s.moveToFolder(ids, folder));
        case 'copy':
          final folder = await pickFolderName(context, store.folders);
          if (folder == null) return;
          await lib.mutate((s) => s.copyToFolder(ids, folder));
        case 'trash':
          await lib.mutate((s) => s.trashItems(ids));
          if (mounted) {
            showMessage(
              context,
              '${ids.length} moved to trash',
              action: SnackBarAction(label: 'Undo', onPressed: () => lib.mutate((s) => s.restore(ids))),
            );
          }
        case 'restore':
          await lib.mutate((s) => s.restore(ids));
        case 'purge':
          if (!await confirm(
            context,
            'Delete permanently?',
            '${ids.length} file(s) will be deleted. This cannot be undone.',
            'Delete',
          )) {
            return;
          }
          await lib.mutate((s) => s.purge(ids));
      }
      setState(_selected.clear);
    } on LibraryException catch (e) {
      if (mounted) showMessage(context, e.message);
    } on NativeError catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(libraryProvider);
    final store = ref.read(libraryStoreProvider);
    final items = store.query(
      text: _query,
      kind: switch (_filter) {
        _Filter.pdf => FileKind.pdf,
        _Filter.image => FileKind.image,
        _ => null,
      },
      favoritesOnly: _filter == _Filter.favorites,
      trashOnly: _filter == _Filter.trash,
      folder: _folder,
      sort: _sort,
    );
    final folders = store.folders;
    final dupGroups = _filter == _Filter.all ? store.duplicates() : const <List<LibraryEntry>>[];
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                tooltip: 'Clear selection',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(_selected.clear),
              )
            : null,
        title: _searching
            ? TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search files',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : Text(_selecting ? '${_selected.length} selected' : 'Files'),
        actions: _selecting
            ? [
                IconButton(
                  tooltip: 'Select all',
                  icon: const Icon(Icons.select_all_rounded),
                  onPressed: () => setState(() => _selected.addAll(items.map((e) => e.id))),
                ),
                if (_filter == _Filter.trash) ...[
                  IconButton(
                    tooltip: 'Restore',
                    icon: const Icon(Icons.restore_rounded),
                    onPressed: () => _bulk('restore'),
                  ),
                  IconButton(
                    tooltip: 'Delete permanently',
                    icon: const Icon(Icons.delete_forever_outlined),
                    onPressed: () => _bulk('purge'),
                  ),
                ] else ...[
                  IconButton(tooltip: 'Share', icon: const Icon(Icons.share_outlined), onPressed: () => _bulk('share')),
                  IconButton(
                    tooltip: 'Move to trash',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _bulk('trash'),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: _bulk,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'export', child: Text('Save to a device folder')),
                      PopupMenuItem(value: 'move', child: Text('Move to folder')),
                      PopupMenuItem(value: 'copy', child: Text('Copy to folder')),
                    ],
                  ),
                ],
              ]
            : [
                IconButton(
                  tooltip: _searching ? 'Close search' : 'Search',
                  icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
                  onPressed: () => setState(() {
                    _searching = !_searching;
                    if (!_searching) _query = '';
                  }),
                ),
                PopupMenuButton<LibrarySort>(
                  tooltip: 'Sort',
                  icon: const Icon(Icons.sort_rounded),
                  initialValue: _sort,
                  onSelected: (v) => setState(() => _sort = v),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: LibrarySort.recent, child: Text('Recent')),
                    PopupMenuItem(value: LibrarySort.name, child: Text('Name')),
                    PopupMenuItem(value: LibrarySort.size, child: Text('Size')),
                    PopupMenuItem(value: LibrarySort.type, child: Text('Type')),
                  ],
                ),
              ],
      ),
      floatingActionButton: _selecting || _filter == _Filter.trash
          ? null
          : FloatingActionButton.extended(
              onPressed: _import,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add files'),
            ),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gaps.page),
              children: [
                for (final f in _Filter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: Gaps.s),
                    child: ChoiceChip(
                      label: Text(switch (f) {
                        _Filter.all => 'All',
                        _Filter.pdf => 'PDFs',
                        _Filter.image => 'Images',
                        _Filter.favorites => 'Favourites',
                        _Filter.trash => 'Trash',
                      }),
                      selected: _filter == f,
                      onSelected: (_) => setState(() {
                        _filter = f;
                        _selected.clear();
                      }),
                    ),
                  ),
              ],
            ),
          ),
          if (folders.isNotEmpty && _filter != _Filter.trash)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Gaps.page),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: Gaps.s),
                    child: FilterChip(
                      label: const Text('All folders'),
                      selected: _folder == null,
                      onSelected: (_) => setState(() => _folder = null),
                    ),
                  ),
                  for (final f in folders)
                    Padding(
                      padding: const EdgeInsets.only(right: Gaps.s),
                      child: FilterChip(
                        avatar: const Icon(Icons.folder_outlined, size: 18),
                        label: Text(f),
                        selected: _folder == f,
                        onSelected: (_) => setState(() => _folder = _folder == f ? null : f),
                      ),
                    ),
                ],
              ),
            ),
          if (_filter == _Filter.trash && items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.s, Gaps.page, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Items are deleted after ${LibraryStore.trashRetention.inDays} days.',
                      style: t.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      if (await confirm(
                        context,
                        'Empty trash?',
                        'All ${items.length} file(s) will be permanently deleted.',
                        'Empty',
                      )) {
                        await ref.read(libraryProvider.notifier).mutate((s) => s.emptyTrash());
                      }
                    },
                    child: const Text('Empty trash'),
                  ),
                ],
              ),
            ),
          if (dupGroups.isNotEmpty && !_selecting)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.s, Gaps.page, 0),
              child: MessageBanner(
                kind: BannerKind.info,
                message: '${dupGroups.length} set${dupGroups.length == 1 ? '' : 's'} of identical files found.',
                action: TextButton(
                  onPressed: () => setState(() {
                    _selected
                      ..clear()
                      ..addAll([for (final g in dupGroups) ...g.skip(1).map((e) => e.id)]);
                  }),
                  child: const Text('Select extra copies'),
                ),
              ),
            ),
          Expanded(
            child: items.isEmpty
                ? EmptyState(
                    icon: _filter == _Filter.trash ? Icons.delete_outline_rounded : Icons.inventory_2_outlined,
                    title: _query.isNotEmpty
                        ? 'No files match “$_query”'
                        : switch (_filter) {
                            _Filter.trash => 'Trash is empty',
                            _Filter.favorites => 'No favourites yet',
                            _ => 'No files yet',
                          },
                    message: _filter == _Filter.all && _query.isEmpty
                        ? 'Files you create or add appear here. They are stored privately on this device.'
                        : null,
                    action: _filter == _Filter.all && _query.isEmpty
                        ? FilledButton.icon(
                            onPressed: _import,
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Add files'),
                          )
                        : null,
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final e = items[i];
                      return LibraryFileTile(
                        entry: e,
                        selected: _selecting ? _selected.contains(e.id) : null,
                        onSelect: () =>
                            setState(() => _selected.contains(e.id) ? _selected.remove(e.id) : _selected.add(e.id)),
                        onLongPress: () => setState(() => _selected.add(e.id)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
