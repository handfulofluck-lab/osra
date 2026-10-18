import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/locale_provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/app_tokens.dart';

/// Settings → Appearance. The theme choice is persisted through
/// `themeModeProvider` (`shared_preferences` key `theme_mode`); `System`
/// follows the device's `platformBrightness`. The language choice is persisted
/// through `localeProvider` (`app_locale`); `System` follows the device locale.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final mode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final tokens = context.tokens;
    final text = Theme.of(context).textTheme;
    final platform = MediaQuery.platformBrightnessOf(context);
    final deviceLanguage = Localizations.localeOf(context).languageCode == 'ar' ? l10n.arabic : l10n.english;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appearanceTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(l10n.themeLabel, style: text.titleMedium),
          const SizedBox(height: AppSpace.xs),
          Text(
            l10n.appearanceDesc,
            style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpace.md),
          SegmentedButton<ThemeMode>(
            key: const ValueKey('themeModeSelector'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: ThemeMode.system, label: Text(l10n.system)),
              ButtonSegment(value: ThemeMode.light, label: Text(l10n.light)),
              ButtonSegment(value: ThemeMode.dark, label: Text(l10n.dark)),
            ],
            selected: {mode},
            onSelectionChanged: (selection) =>
                ref.read(themeModeProvider.notifier).setMode(selection.first),
          ),
          const SizedBox(height: AppSpace.lg),
          Text(
            switch (mode) {
              ThemeMode.system => l10n.followingDevice(platform == Brightness.dark ? l10n.dark : l10n.light),
              ThemeMode.light => l10n.lightAlwaysOn,
              ThemeMode.dark => l10n.darkAlwaysOn,
            },
            style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpace.xl),
          Text(l10n.languageLabel, style: text.titleMedium),
          const SizedBox(height: AppSpace.xs),
          Text(
            l10n.languageDesc,
            style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpace.md),
          InputDecorator(
            decoration: const InputDecoration(border: OutlineInputBorder()),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const ValueKey('localeSelector'),
                value: appLocaleName(locale),
                isExpanded: true,
                items: [
                  DropdownMenuItem(value: 'system', child: Text(l10n.system)),
                  DropdownMenuItem(value: 'en', child: Text(l10n.english)),
                  DropdownMenuItem(value: 'ar', child: Text(l10n.arabic)),
                ],
                onChanged: (value) =>
                    ref.read(localeProvider.notifier).setLocale(appLocaleFromName(value)),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            switch (locale?.languageCode) {
              'en' => l10n.englishAlwaysOn,
              'ar' => l10n.arabicAlwaysOn,
              _ => l10n.followingLanguage(deviceLanguage),
            },
            style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
