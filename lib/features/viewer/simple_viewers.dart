import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/files/library_store.dart';
import '../../core/providers.dart';
import '../image/engine/image_engine.dart';

class ImageViewerScreen extends ConsumerWidget {
  const ImageViewerScreen({super.key, required this.entry});
  final LibraryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.read(libraryStoreProvider);
    final api = ref.read(nativeApiProvider);
    final file = store.fileOf(entry);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => api.share([file.path], entry.mime),
          ),
          IconButton(
            tooltip: 'Use in a tool',
            icon: const Icon(Icons.handyman_outlined),
            onPressed: () => context.push('/continue', extra: entry),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              maxScale: 10,
              child: Center(
                child: Image.file(
                  file,
                  errorBuilder: (_, _, _) =>
                      const EmptyState(icon: Icons.broken_image_outlined, title: 'Cannot display this image'),
                ),
              ),
            ),
          ),
          FutureBuilder(
            future: Future(() async => probeImage(await file.readAsBytes())),
            builder: (context, snap) => SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(Gaps.l),
                child: Text(
                  snap.hasData
                      ? '${snap.data!.width} × ${snap.data!.height} px · ${formatBytes(entry.size)}'
                      : formatBytes(entry.size),
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: Colors.white70),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TextViewerScreen extends ConsumerWidget {
  const TextViewerScreen({super.key, required this.entry});
  final LibraryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = ref.read(libraryStoreProvider).fileOf(entry);
    return Scaffold(
      appBar: AppBar(
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => ref.read(nativeApiProvider).share([file.path], 'text/plain'),
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: File(file.path).readAsString(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const EmptyState(icon: Icons.error_outline, title: 'This file could not be read as text');
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return SingleChildScrollView(
            padding: const EdgeInsets.all(Gaps.page),
            child: SelectableText(snap.data!, style: Theme.of(context).textTheme.bodyMedium),
          );
        },
      ),
    );
  }
}
