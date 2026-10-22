import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/library_store.dart';
import '../../core/providers.dart';
import '../../core/tooling/inputs.dart';
import '../../core/tooling/tool_scaffold.dart';

/// Read-only PDF viewer: zoom, page navigation, text search and selection.
class PdfViewerScreen extends ConsumerStatefulWidget {
  const PdfViewerScreen({super.key, required this.entry});
  final LibraryEntry entry;

  @override
  ConsumerState<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends ConsumerState<PdfViewerScreen> {
  final _controller = PdfViewerController();
  late final PdfTextSearcher _searcher = PdfTextSearcher(_controller)..addListener(_onSearch);
  final _query = TextEditingController();
  bool _searching = false;
  int? _page;
  int _pageCount = 0;
  String? _password;
  int _passwordAttempts = 0;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(libraryProvider.notifier).mutate((s) => s.markOpened(widget.entry.id)));
  }

  void _onSearch() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searcher.removeListener(_onSearch);
    _searcher.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<String?> _passwordProvider() async {
    if (!mounted) return null;
    final pw = await askPassword(context, widget.entry.name, wrong: _passwordAttempts > 0);
    _passwordAttempts++;
    _password = pw;
    return pw;
  }

  InputFile get _asInput {
    final store = ref.read(libraryStoreProvider);
    return InputFile.fromEntry(store, widget.entry)..password = _password;
  }

  void _openTools() {
    context.push('/continue', extra: widget.entry);
  }

  Future<void> _goToPageDialog() async {
    final controller = TextEditingController(text: '${_page ?? 1}');
    final page = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: 'Page (1–$_pageCount)'),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(controller.text)), child: const Text('Go')),
        ],
      ),
    );
    if (page != null && page >= 1 && page <= _pageCount) {
      await _controller.goToPage(pageNumber: page);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.read(libraryStoreProvider);
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final api = ref.read(nativeApiProvider);
    final path = store.fileOf(widget.entry).path;
    return Scaffold(
      appBar: _searching
          ? AppBar(
              leading: IconButton(
                tooltip: 'Close search',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () {
                  _searcher.resetTextSearch();
                  setState(() => _searching = false);
                },
              ),
              titleSpacing: 0,
              title: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Search in document',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                onChanged: (v) => _searcher.startTextSearch(v, caseInsensitive: true),
                onSubmitted: (_) => _searcher.goToNextMatch(),
              ),
              actions: [
                if (_searcher.isSearching)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (_query.text.isNotEmpty)
                  Center(
                    child: Text(
                      _searcher.matches.isEmpty
                          ? 'No results'
                          : '${(_searcher.currentIndex ?? 0) + 1}/${_searcher.matches.length}',
                      style: t.labelLarge,
                    ),
                  ),
                IconButton(
                  tooltip: 'Previous result',
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  onPressed: _searcher.hasMatches ? () => _searcher.goToPrevMatch() : null,
                ),
                IconButton(
                  tooltip: 'Next result',
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  onPressed: _searcher.hasMatches ? () => _searcher.goToNextMatch() : null,
                ),
              ],
            )
          : AppBar(
              title: Text(widget.entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.search_rounded),
                  onPressed: () => setState(() => _searching = true),
                ),
                IconButton(
                  tooltip: 'Share',
                  icon: const Icon(Icons.share_outlined),
                  onPressed: () => api.share([path], 'application/pdf'),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (v) async {
                    switch (v) {
                      case 'tools':
                        _openTools();
                      case 'save':
                        await saveEntryToDevice(context, ref, widget.entry);
                      case 'print':
                        await api.printFile(path, widget.entry.name);
                      case 'edit':
                        unawaited(context.push('/tool/edit_pdf', extra: [_asInput]));
                      case 'sign':
                        unawaited(context.push('/tool/sign_pdf', extra: [_asInput]));
                      case 'goto':
                        await _goToPageDialog();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit & annotate')),
                    ),
                    PopupMenuItem(
                      value: 'sign',
                      child: ListTile(leading: Icon(Icons.draw_outlined), title: Text('Sign')),
                    ),
                    PopupMenuItem(
                      value: 'tools',
                      child: ListTile(leading: Icon(Icons.handyman_outlined), title: Text('More tools')),
                    ),
                    PopupMenuItem(
                      value: 'goto',
                      child: ListTile(leading: Icon(Icons.numbers_rounded), title: Text('Go to page')),
                    ),
                    PopupMenuItem(
                      value: 'save',
                      child: ListTile(leading: Icon(Icons.download_rounded), title: Text('Save to device')),
                    ),
                    PopupMenuItem(
                      value: 'print',
                      child: ListTile(leading: Icon(Icons.print_outlined), title: Text('Print')),
                    ),
                  ],
                ),
              ],
            ),
      body: PdfViewer.file(
        path,
        controller: _controller,
        passwordProvider: _passwordProvider,
        params: PdfViewerParams(
          backgroundColor: s.surfaceContainer,
          margin: 12,
          pageDropShadow: BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
          textSelectionParams: const PdfTextSelectionParams(enabled: true),
          pagePaintCallbacks: [_searcher.pageTextMatchPaintCallback],
          onViewerReady: (document, controller) {
            setState(() {
              _pageCount = document.pages.length;
              _page = controller.pageNumber ?? 1;
            });
          },
          onPageChanged: (n) => setState(() => _page = n),
          loadingBannerBuilder: (context, done, total) => const Center(child: CircularProgressIndicator()),
          errorBannerBuilder: (context, error, stack, ref) => EmptyState(
            icon: Icons.broken_image_outlined,
            title: 'This PDF could not be opened',
            message: _password == null && _passwordAttempts > 0
                ? 'A password is required.'
                : 'It may be damaged or use an unsupported format.',
          ),
          viewerOverlayBuilder: (context, size, handleLinkTap) => [
            PdfViewerScrollThumb(
              controller: _controller,
              orientation: ScrollbarOrientation.right,
              thumbSize: const Size(44, 28),
              thumbBuilder: (context, thumbSize, pageNumber, controller) => Container(
                decoration: BoxDecoration(color: s.inverseSurface, borderRadius: BorderRadius.circular(Radii.s)),
                alignment: Alignment.center,
                child: Text('${pageNumber ?? ''}', style: t.labelMedium!.copyWith(color: s.onInverseSurface)),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _pageCount == 0
          ? null
          : SafeArea(
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: Gaps.s),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous page',
                      icon: const Icon(Icons.chevron_left_rounded),
                      onPressed: (_page ?? 1) > 1 ? () => _controller.goToPage(pageNumber: (_page ?? 1) - 1) : null,
                    ),
                    Expanded(
                      child: TextButton(
                        onPressed: _goToPageDialog,
                        child: Text('Page ${_page ?? 1} of $_pageCount', style: t.labelLarge),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Zoom out',
                      icon: const Icon(Icons.zoom_out_rounded),
                      onPressed: () => _controller.zoomDown(),
                    ),
                    IconButton(
                      tooltip: 'Zoom in',
                      icon: const Icon(Icons.zoom_in_rounded),
                      onPressed: () => _controller.zoomUp(),
                    ),
                    IconButton(
                      tooltip: 'Next page',
                      icon: const Icon(Icons.chevron_right_rounded),
                      onPressed: (_page ?? 1) < _pageCount
                          ? () => _controller.goToPage(pageNumber: (_page ?? 1) + 1)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
