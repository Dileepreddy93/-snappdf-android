import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/design/widgets.dart';
import '../../core/files/file_kind.dart';
import '../../core/providers.dart';
import '../pdf/convert_tools.dart';

final _storageProvider = FutureProvider.autoDispose<({int library, int trash, int temp})>((ref) async {
  ref.watch(libraryProvider);
  final ws = ref.watch(workspaceProvider);
  return (
    library: await ws.directorySize(ws.libraryDir),
    trash: await ws.directorySize(ws.trashDir),
    temp: await ws.directorySize(ws.cache),
  );
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final storage = ref.watch(_storageProvider);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const SectionHeader('Appearance', padding: EdgeInsets.fromLTRB(Gaps.page, Gaps.s, Gaps.page, Gaps.s)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gaps.page),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('System'),
                  icon: Icon(Icons.brightness_auto_outlined),
                ),
                ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (v) => ctrl.setThemeMode(v.first),
            ),
          ),
          const SectionHeader('Defaults'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gaps.page),
            child: LabeledSlider(
              label: 'Default photo quality',
              value: settings.defaultJpegQuality.toDouble(),
              min: 50,
              max: 100,
              divisions: 10,
              onChanged: (v) => ctrl.update((s) => s.copyWith(defaultJpegQuality: v.round())),
            ),
          ),
          ListTile(
            title: const Text('Text recognition language'),
            subtitle: Text(ocrScripts[settings.ocrScript] ?? settings.ocrScript),
            trailing: DropdownButton<String>(
              value: settings.ocrScript,
              underline: const SizedBox.shrink(),
              items: [
                for (final e in ocrScripts.keys)
                  DropdownMenuItem(value: e, child: Text(e == 'latin' ? 'English' : 'Hindi')),
              ],
              onChanged: (v) => ctrl.update((s) => s.copyWith(ocrScript: v)),
            ),
          ),
          SwitchListTile(
            value: settings.stripPdfMetadata,
            onChanged: (v) => ctrl.update((s) => s.copyWith(stripPdfMetadata: v)),
            title: const Text('Remove PDF metadata when compressing'),
          ),
          ListTile(
            title: const Text('Author name for comments'),
            subtitle: Text(settings.authorName.isEmpty ? 'Not set' : settings.authorName),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () async {
              final c = TextEditingController(text: settings.authorName);
              final v = await showDialog<String>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Author name'),
                  content: TextField(
                    controller: c,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Name (optional)'),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Save')),
                  ],
                ),
              );
              if (v != null) await ctrl.update((s) => s.copyWith(authorName: v));
            },
          ),
          const SectionHeader('Storage'),
          storage.when(
            loading: () => const ListTile(title: Text('Calculating…')),
            error: (e, _) => ListTile(title: Text('Could not calculate: $e')),
            data: (s) => Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: const Text('Your files'),
                  trailing: Text(formatBytes(s.library)),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('Trash'),
                  trailing: Text(formatBytes(s.trash)),
                ),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('Temporary files'),
                  subtitle: const Text('Intermediate files from processing'),
                  trailing: TextButton(
                    onPressed: () async {
                      await ref.read(workspaceProvider).cleanWork(maxAge: Duration.zero);
                      try {
                        await ref.read(nativeApiProvider).cleanTemp();
                      } catch (_) {}
                      ref.invalidate(_storageProvider);
                      if (context.mounted) showMessage(context, 'Temporary files cleared');
                    },
                    child: Text('Clear ${formatBytes(s.temp)}'),
                  ),
                ),
              ],
            ),
          ),
          const SectionHeader('Privacy'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gaps.page),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(Gaps.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your documents stay on this device', style: t.titleSmall),
                    const SizedBox(height: Gaps.s),
                    Text(
                      '• All processing — PDF editing, compression, OCR and background removal — runs on your phone.\n'
                      '• SnapPDF has no internet permission and cannot upload your files.\n'
                      '• Files are stored in the app’s private storage and excluded from cloud backups.\n'
                      '• Saved signatures are encrypted with a key kept in the Android Keystore.\n'
                      '• Files leave the app only when you choose Save, Share or Print.\n'
                      '• The document scanner is provided by Google Play services on your device.',
                      style: t.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('SnapPDF'),
            subtitle: const Text('Version 0.1.0 (beta)'),
            onTap: () => showAboutDialog(context: context, applicationName: 'SnapPDF', applicationVersion: '0.1.0'),
          ),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('Open-source licences'),
            onTap: () => showLicensePage(context: context, applicationName: 'SnapPDF'),
          ),
          const SizedBox(height: Gaps.xxl),
        ],
      ),
    );
  }
}
