import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';
import '../files/file_tile.dart';
import '../tools/tool_registry.dart';

const _quick = ['scan', 'images_to_pdf', 'compress_pdf', 'merge_pdf', 'sign_pdf', 'compress_image'];

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _openPdf(BuildContext context, WidgetRef ref) async {
    final picked = await pickInputs(context, ref, accept: Accept.pdf);
    if (picked.isEmpty || !context.mounted) return;
    final f = picked.first;
    final store = ref.read(libraryStoreProvider);
    final entry = f.libraryId != null
        ? store.byId(f.libraryId!)!
        : (await ref.read(libraryProvider.notifier).addImported(f.path, f.name)).entry;
    if (context.mounted) openEntry(context, entry);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(libraryProvider);
    final store = ref.read(libraryStoreProvider);
    final recent = store.query().take(5).toList();
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 720 ? 6 : 3;
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.l, Gaps.page, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const ToneIcon(Icons.description_rounded, size: 36),
                        const SizedBox(width: Gaps.m),
                        Text('SnapPDF', style: t.headlineSmall),
                      ],
                    ),
                    const SizedBox(height: Gaps.l),
                    Hero(
                      tag: 'search',
                      child: Material(
                        type: MaterialType.transparency,
                        child: _SearchEntry(onTap: () => context.push('/search')),
                      ),
                    ),
                    const SizedBox(height: Gaps.l),
                    Card(
                      color: s.primaryContainer,
                      child: InkWell(
                        onTap: () => _openPdf(context, ref),
                        child: Padding(
                          padding: const EdgeInsets.all(Gaps.l),
                          child: Row(
                            children: [
                              Icon(Icons.folder_open_rounded, color: s.onPrimaryContainer, size: 28),
                              const SizedBox(width: Gaps.l),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Open a PDF', style: t.titleMedium!.copyWith(color: s.onPrimaryContainer)),
                                    Text(
                                      'View, search, sign and edit',
                                      style: t.bodyMedium!.copyWith(color: s.onPrimaryContainer),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right_rounded, color: s.onPrimaryContainer),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SectionHeader('Quick actions')),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Gaps.page),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: Gaps.m,
                  crossAxisSpacing: Gaps.m,
                  // Fixed height that grows with the user's text size.
                  mainAxisExtent: 76 + MediaQuery.textScalerOf(context).scale(40),
                ),
                delegate: SliverChildListDelegate([
                  for (final id in _quick)
                    if (toolById(id) case final tool?)
                      _QuickAction(tool: tool, onTap: () => context.push('/tool/${tool.id}')),
                ]),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.xl, Gaps.page, 0),
                child: Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: Gaps.l, vertical: Gaps.s),
                    leading: const ToneIcon(Icons.auto_awesome_rounded, tone: Tone.secondary),
                    title: const Text('Smart File Fix'),
                    subtitle: const Text(
                      'Need a 200 KB JPG or a 2 MB PDF for an application? Describe it and SnapPDF does the rest.',
                    ),
                    onTap: () => context.push('/tool/smart_fix'),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SectionHeader(
                'Recent files',
                action: recent.isEmpty
                    ? null
                    : TextButton(onPressed: () => context.go('/files'), child: const Text('See all')),
              ),
            ),
            if (recent.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gaps.page),
                  child: Text(
                    'Files you create or open appear here. Everything stays on this device.',
                    style: t.bodyMedium!.copyWith(color: s.onSurfaceVariant),
                  ),
                ),
              )
            else
              SliverList.list(children: [for (final e in recent) LibraryFileTile(entry: e)]),
            const SliverToBoxAdapter(child: SizedBox(height: Gaps.xxl)),
          ],
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.tool, required this.onTap});
  final ToolDef tool;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gaps.s, vertical: Gaps.m),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ToneIcon(tool.icon, tone: tool.tone, size: 44),
              const SizedBox(height: Gaps.s),
              Text(
                tool.title,
                style: t.labelLarge,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 900
        ? 4
        : width >= 600
        ? 3
        : 2;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tools'),
        actions: [
          IconButton(
            tooltip: 'Search tools',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          for (final cat in ToolCategory.values) ...[
            SliverToBoxAdapter(
              child: SectionHeader(cat.label, padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.l, Gaps.page, Gaps.s)),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Gaps.page),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: Gaps.m,
                  crossAxisSpacing: Gaps.m,
                  // Icon + padding, plus two title lines and one subtitle line at the user's text size.
                  mainAxisExtent: 90 + MediaQuery.textScalerOf(context).scale(58),
                ),
                delegate: SliverChildListDelegate([
                  for (final tool in allTools.where((t) => t.category == cat))
                    ToolTile(
                      icon: tool.icon,
                      title: tool.title,
                      subtitle: tool.subtitle,
                      tone: tool.tone,
                      onTap: () => context.push('/tool/${tool.id}'),
                    ),
                ]),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: Gaps.xxl)),
        ],
      ),
    );
  }
}

/// Global search over tools and library files.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    ref.watch(libraryProvider);
    final store = ref.read(libraryStoreProvider);
    final tools = searchTools(_q);
    final files = _q.trim().isEmpty ? const [] : store.query(text: _q).take(20).toList();
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: Gaps.l),
          child: Hero(
            tag: 'search',
            child: Material(
              type: MaterialType.transparency,
              child: SearchBar(
                autoFocus: true,
                hintText: 'Search tools and files',
                leading: const Icon(Icons.search_rounded),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        children: [
          if (tools.isEmpty && files.isEmpty)
            EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Nothing found',
              message: 'Try “compress”, “sign”, “jpg” or a file name.',
            ),
          if (tools.isNotEmpty)
            SectionHeader(
              'Tools (${tools.length})',
              padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.m, Gaps.page, Gaps.s),
            ),
          for (final tool in tools)
            ListTile(
              leading: ToneIcon(tool.icon, tone: tool.tone, size: 40),
              title: Text(tool.title),
              subtitle: Text(tool.subtitle),
              onTap: () => context.pushReplacement('/tool/${tool.id}'),
            ),
          if (files.isNotEmpty) ...[
            SectionHeader('Files (${files.length})'),
            for (final e in files) LibraryFileTile(entry: e),
          ],
          if (_q.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gaps.page),
              child: Text('Tip: search by task, e.g. “reduce size”, “password”, “passport”.', style: t.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// "Continue with…" — tools that accept a given file.
class ContinueScreen extends ConsumerWidget {
  const ContinueScreen({super.key, required this.entryId});
  final String entryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.read(libraryStoreProvider);
    final entry = store.byId(entryId);
    if (entry == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(icon: Icons.help_outline, title: 'File not found'),
      );
    }
    final tools = allTools.where((t) => t.accepts.contains(entry.kind)).toList();
    return Scaffold(
      appBar: AppBar(title: Text('Continue with ${entry.name}', maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(
        children: [
          if (entry.kind == FileKind.pdf || entry.kind == FileKind.image || entry.kind == FileKind.text)
            ListTile(
              leading: const ToneIcon(Icons.visibility_outlined, tone: Tone.neutral, size: 40),
              title: const Text('Open'),
              onTap: () => openEntry(context, entry),
            ),
          for (final tool in tools)
            ListTile(
              leading: ToneIcon(tool.icon, tone: tool.tone, size: 40),
              title: Text(tool.title),
              subtitle: Text(tool.subtitle),
              onTap: () => context.push('/tool/${tool.id}', extra: [InputFile.fromEntry(store, entry)]),
            ),
        ],
      ),
    );
  }
}

/// Looks like a search field but is a button that opens the search page,
/// so it has one clear, full-size tap target for accessibility services.
class _SearchEntry extends StatelessWidget {
  const _SearchEntry({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Search tools and files',
      excludeSemantics: true,
      child: Material(
        color: s.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.xl),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.xl),
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                const SizedBox(width: Gaps.l),
                Icon(Icons.search_rounded, color: s.onSurface),
                const SizedBox(width: Gaps.l),
                Expanded(
                  child: Text('Search tools and files', style: t.bodyLarge!.copyWith(color: s.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
