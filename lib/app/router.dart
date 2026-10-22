import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/design/widgets.dart';
import '../core/files/library_store.dart';
import '../core/tooling/inputs.dart';
import '../features/files/files_screen.dart';
import '../features/home/home_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/tools/tool_registry.dart';
import '../features/viewer/pdf_viewer_screen.dart';
import '../features/viewer/simple_viewers.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

GoRouter buildRouter() => GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/home',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => AppShell(shell: shell),
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/tools', builder: (_, _) => const ToolsScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/files', builder: (_, _) => const FilesScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen())],
        ),
      ],
    ),
    GoRoute(
      path: '/tool/:id',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        final tool = toolById(state.pathParameters['id']!);
        if (tool == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(icon: Icons.help_outline, title: 'Tool not found'),
          );
        }
        final inputs = state.extra is List<InputFile> ? state.extra as List<InputFile> : const <InputFile>[];
        return tool.build(inputs);
      },
    ),
    GoRoute(path: '/search', parentNavigatorKey: rootNavigatorKey, builder: (_, _) => const SearchScreen()),
    GoRoute(
      path: '/viewer',
      parentNavigatorKey: rootNavigatorKey,
      builder: (_, state) => PdfViewerScreen(entry: state.extra! as LibraryEntry),
    ),
    GoRoute(
      path: '/image-viewer',
      parentNavigatorKey: rootNavigatorKey,
      builder: (_, state) => ImageViewerScreen(entry: state.extra! as LibraryEntry),
    ),
    GoRoute(
      path: '/text-viewer',
      parentNavigatorKey: rootNavigatorKey,
      builder: (_, state) => TextViewerScreen(entry: state.extra! as LibraryEntry),
    ),
    GoRoute(
      path: '/continue',
      parentNavigatorKey: rootNavigatorKey,
      builder: (_, state) => ContinueScreen(entryId: (state.extra! as LibraryEntry).id),
    ),
  ],
);

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const _destinations = [
    NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
    NavigationDestination(icon: Icon(Icons.apps_outlined), selectedIcon: Icon(Icons.apps_rounded), label: 'Tools'),
    NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder_rounded), label: 'Files'),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings_rounded),
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    void go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: shell.currentIndex,
              onDestinationSelected: go,
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(icon: d.icon, selectedIcon: d.selectedIcon, label: Text(d.label)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: shell),
          ],
        ),
      );
    }
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: go,
        destinations: _destinations,
      ),
    );
  }
}
