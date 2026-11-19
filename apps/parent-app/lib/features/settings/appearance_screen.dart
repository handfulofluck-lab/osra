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
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final labelStyle = text.labelLarge;
    final availableWidth = MediaQuery.sizeOf(context).width - 2 * AppSpace.lg - 96;

    double measureLabel(String label) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        maxLines: 1,
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      return painter.width;
    }

    final maxLabelWidth = [
      measureLabel(l10n.system),
      measureLabel(l10n.light),
      measureLabel(l10n.dark),
    ].reduce((a, b) => a > b ? a : b);
    final fitsSingleLine = availableWidth > 0 && maxLabelWidth * 3 <= availableWidth;

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
          if (fitsSingleLine)
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
            )
          else
            Column(
              key: const ValueKey('themeModeSelector'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (option, label) in [
                  (ThemeMode.system, l10n.system),
                  (ThemeMode.light, l10n.light),
                  (ThemeMode.dark, l10n.dark),
                ])
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      bottom: option == ThemeMode.dark ? 0 : AppSpace.sm,
                    ),
                    child: Semantics(
                      inMutuallyExclusiveGroup: true,
                      selected: mode == option,
                      button: true,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          padding: const EdgeInsetsDirectional.symmetric(
                            horizontal: AppSpace.lg,
                            vertical: AppSpace.md,
                          ),
                          alignment: AlignmentDirectional.centerStart,
                          backgroundColor:
                              mode == option ? tokens.primaryContainer : null,
                          foregroundColor: mode == option
                              ? tokens.onPrimaryContainer
                              : tokens.onSurface,
                          side: BorderSide(
                            color:
                                mode == option ? tokens.primary : tokens.border,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                        ),
                        onPressed: () =>
                            ref.read(themeModeProvider.notifier).setMode(option),
                        child: Row(
                          children: [
                            Icon(
                              mode == option
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              color: mode == option
                                  ? tokens.primary
                                  : tokens.onSurfaceVariant,
                            ),
                            const SizedBox(width: AppSpace.md),
                            Expanded(
                              child: Text(
                                label,
                                style: labelStyle?.copyWith(
                                  color: mode == option
                                      ? tokens.onPrimaryContainer
                                      : tokens.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
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
