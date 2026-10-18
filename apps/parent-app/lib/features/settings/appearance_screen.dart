import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_provider.dart';
import '../../theme/app_tokens.dart';

/// Settings → Appearance. The choice is persisted through
/// `themeModeProvider` (`shared_preferences` key `theme_mode`); `System`
/// follows the device's `platformBrightness`.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final tokens = context.tokens;
    final text = Theme.of(context).textTheme;
    final platform = MediaQuery.platformBrightnessOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text('Theme', style: text.titleMedium),
          const SizedBox(height: AppSpace.xs),
          Text(
            'System follows this device. Light or Dark overrides it for OSRA only.',
            style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpace.md),
          SegmentedButton<ThemeMode>(
            key: const ValueKey('themeModeSelector'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ButtonSegment(value: ThemeMode.light, label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
            ],
            selected: {mode},
            onSelectionChanged: (selection) =>
                ref.read(themeModeProvider.notifier).setMode(selection.first),
          ),
          const SizedBox(height: AppSpace.lg),
          Text(
            switch (mode) {
              ThemeMode.system => 'Following the device (currently '
                  '${platform == Brightness.dark ? 'dark' : 'light'}).',
              ThemeMode.light => 'Light theme is always on.',
              ThemeMode.dark => 'Dark theme is always on.',
            },
            style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
