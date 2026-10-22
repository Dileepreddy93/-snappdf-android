import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/files/library_store.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';
import '../../core/tooling/tool_scaffold.dart';

String relativeDate(DateTime d) {
  final now = DateTime.now();
  final diff = now.difference(d);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  if (diff.inDays < 1 && now.day == d.day) return DateFormat.jm().format(d);
  if (diff.inDays < 7) return DateFormat.E().add_jm().format(d);
  return DateFormat.yMMMd().format(d);
}

class LibraryFileTile extends ConsumerWidget {
  const LibraryFileTile({super.key, required this.entry, this.selected, this.onSelect, this.onLongPress});
  final LibraryEntry entry;

  /// Non-null in selection mode.
  final bool? selected;
  final VoidCallback? onSelect;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.read(libraryStoreProvider);
    final path = store.fileOf(entry).path;
    return ListTile(
      leading: FileThumb(name: entry.name, path: path, size: 48),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [formatBytes(entry.size), relativeDate(entry.lastUsed), if (entry.folder.isNotEmpty) entry.folder].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      selected: selected ?? false,
      trailing: selected != null
          ? Checkbox(value: selected, onChanged: (_) => onSelect?.call())
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (entry.favorite) Icon(Icons.star_rounded, size: 20, color: Theme.of(context).colorScheme.primary),
                IconButton(
                  tooltip: 'More options for ${entry.name}',
                  icon: const Icon(Icons.more_vert_rounded),
                  onPressed: () => showFileActions(context, ref, entry),
                ),
              ],
            ),
      onTap: selected != null
          ? onSelect
          : () => entry.inTrash ? showFileActions(context, ref, entry) : openEntry(context, entry),
      onLongPress: onLongPress,
    );
  }
}

Future<String?> askName(BuildContext context, {required String title, String initial = '', String label = 'Name'}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('OK')),
      ],
    ),
  );
}

/// Picks a folder name (existing or new). Returns '' for top level, null if cancelled.
Future<String?> pickFolderName(BuildContext context, List<String> folders) => showModalBottomSheet<String>(
  context: context,
  builder: (context) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      children: [
        ListTile(
          leading: const Icon(Icons.home_outlined),
          title: const Text('Top level'),
          onTap: () => Navigator.pop(context, ''),
        ),
        for (final f in folders)
          ListTile(leading: const Icon(Icons.folder_outlined), title: Text(f), onTap: () => Navigator.pop(context, f)),
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('New folder…'),
          onTap: () async {
            final name = await askName(context, title: 'New folder', label: 'Folder name');
            if (context.mounted) Navigator.pop(context, name?.trim().isEmpty ?? true ? null : name!.trim());
          },
        ),
      ],
    ),
  ),
);

Future<void> showFileActions(BuildContext context, WidgetRef ref, LibraryEntry entry) async {
  final store = ref.read(libraryStoreProvider);
  final lib = ref.read(libraryProvider.notifier);
  final api = ref.read(nativeApiProvider);
  final path = store.fileOf(entry).path;
  final t = Theme.of(context).textTheme;
  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gaps.page, 0, Gaps.page, Gaps.m),
              child: Row(
                children: [
                  FileThumb(name: entry.name, path: path, size: 52),
                  const SizedBox(width: Gaps.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.name, style: t.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text('${formatBytes(entry.size)} · ${entry.kind.label}', style: t.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (entry.inTrash) ...[
              ListTile(
                leading: const Icon(Icons.restore_rounded),
                title: const Text('Restore'),
                onTap: () => Navigator.pop(context, 'restore'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: const Text('Delete permanently'),
                onTap: () => Navigator.pop(context, 'purge'),
              ),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: const Text('Open'),
                onTap: () => Navigator.pop(context, 'open'),
              ),
              ListTile(
                leading: const Icon(Icons.handyman_outlined),
                title: const Text('Use in a tool'),
                onTap: () => Navigator.pop(context, 'tools'),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Share'),
                onTap: () => Navigator.pop(context, 'share'),
              ),
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Save to device'),
                onTap: () => Navigator.pop(context, 'save'),
              ),
              if (entry.kind == FileKind.pdf || entry.kind == FileKind.image)
                ListTile(
                  leading: const Icon(Icons.print_outlined),
                  title: const Text('Print'),
                  onTap: () => Navigator.pop(context, 'print'),
                ),
              ListTile(
                leading: Icon(entry.favorite ? Icons.star_rounded : Icons.star_outline_rounded),
                title: Text(entry.favorite ? 'Remove from favourites' : 'Add to favourites'),
                onTap: () => Navigator.pop(context, 'favorite'),
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('Rename'),
                onTap: () => Navigator.pop(context, 'rename'),
              ),
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Duplicate'),
                onTap: () => Navigator.pop(context, 'duplicate'),
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline),
                title: const Text('Move to folder'),
                onTap: () => Navigator.pop(context, 'move'),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('Details & history'),
                onTap: () => Navigator.pop(context, 'details'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Move to trash'),
                onTap: () => Navigator.pop(context, 'trash'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  try {
    switch (action) {
      case 'open':
        openEntry(context, entry);
      case 'tools':
        unawaited(context.push('/continue', extra: entry));
      case 'share':
        await api.share([path], entry.mime);
      case 'save':
        await saveEntryToDevice(context, ref, entry);
      case 'print':
        await api.printFile(path, entry.name);
      case 'favorite':
        await lib.mutate((s) => s.setFavorite(entry.id, !entry.favorite));
      case 'rename':
        final name = await askName(context, title: 'Rename', initial: entry.name);
        if (name != null) await lib.mutate((s) => s.rename(entry.id, name));
      case 'duplicate':
        final copy = await lib.mutate((s) => s.duplicate(entry.id));
        if (context.mounted) showMessage(context, 'Created “${copy.name}”');
      case 'move':
        final folder = await pickFolderName(context, store.folders);
        if (folder != null) await lib.mutate((s) => s.moveToFolder([entry.id], folder));
      case 'details':
        if (context.mounted) await showDetails(context, ref, entry);
      case 'trash':
        await lib.mutate((s) => s.trashItems([entry.id]));
        if (context.mounted) {
          showMessage(
            context,
            'Moved to trash',
            action: SnackBarAction(label: 'Undo', onPressed: () => lib.mutate((s) => s.restore([entry.id]))),
          );
        }
      case 'restore':
        await lib.mutate((s) => s.restore([entry.id]));
      case 'purge':
        final ok = await confirm(
          context,
          'Delete permanently?',
          '“${entry.name}” will be deleted. This cannot be undone.',
          'Delete',
        );
        if (ok) await lib.mutate((s) => s.purge([entry.id]));
    }
  } on LibraryException catch (e) {
    if (context.mounted) showMessage(context, e.message);
  } on NativeError catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
}

Future<bool> confirm(BuildContext context, String title, String message, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    ) ??
    false;

Future<void> showDetails(BuildContext context, WidgetRef ref, LibraryEntry entry) async {
  final api = ref.read(nativeApiProvider);
  final store = ref.read(libraryStoreProvider);
  final df = DateFormat.yMMMd().add_jm();
  PdfInfo? info;
  if (entry.kind == FileKind.pdf) {
    try {
      info = await api.pdfInfo(store.fileOf(entry).path);
    } catch (_) {}
  }
  final duplicates = store.active.where((e) => e.id != entry.id && e.sha256 == entry.sha256).toList();
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(Gaps.page, 0, Gaps.page, Gaps.xl),
        children: [
          Text(entry.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gaps.m),
          InfoRow('Type', entry.kind.label),
          InfoRow('Size', '${formatBytes(entry.size)} (${NumberFormat.decimalPattern().format(entry.size)} bytes)'),
          if (info != null) InfoRow('Pages', '${info.pageCount}${info.encrypted ? ' · password protected' : ''}'),
          InfoRow('Created', df.format(entry.createdAt)),
          InfoRow('Modified', df.format(entry.modifiedAt)),
          if (entry.folder.isNotEmpty) InfoRow('Folder', entry.folder),
          InfoRow('SHA-256', entry.sha256),
          if (duplicates.isNotEmpty) ...[
            const SizedBox(height: Gaps.m),
            MessageBanner(
              kind: BannerKind.warning,
              message: 'Identical copies: ${duplicates.map((d) => d.name).join(', ')}',
            ),
          ],
          const SizedBox(height: Gaps.l),
          Text('History', style: Theme.of(context).textTheme.titleSmall),
          for (final h in entry.history.reversed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.history_rounded, size: 20),
              title: Text(h.detail == null ? h.action : '${h.action} · ${h.detail}'),
              subtitle: Text(df.format(h.at)),
            ),
        ],
      ),
    ),
  );
}
