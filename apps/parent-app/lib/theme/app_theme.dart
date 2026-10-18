import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// The parent app's two themes. Both are built from the same token layer
/// ([AppTokens], [AppSpace], [AppRadius], [AppElevation], [AppType]); screens
/// consume roles from `Theme.of(context)`/`context.tokens` instead of naming
/// colours, gaps or inline [TextStyle]s of their own.
abstract final class AppTheme {
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final tokens = brightness == Brightness.dark ? AppTokens.dark : AppTokens.light;
    final seeded = ColorScheme.fromSeed(
      seedColor: tokens.primary,
      brightness: brightness,
    );
    final scheme = seeded.copyWith(
      primary: tokens.primary,
      onPrimary: tokens.onPrimary,
      primaryContainer: tokens.primaryContainer,
      onPrimaryContainer: tokens.onPrimaryContainer,
      surface: tokens.surface,
      onSurface: tokens.onSurface,
      onSurfaceVariant: tokens.onSurfaceVariant,
      surfaceContainerLowest: tokens.surface,
      surfaceContainerLow: tokens.surfaceContainer,
      surfaceContainer: tokens.surfaceContainer,
      surfaceContainerHigh: tokens.surfaceVariant,
      surfaceContainerHighest: tokens.surfaceVariant,
      error: tokens.danger,
      onError: tokens.onDanger,
      outline: tokens.border,
      outlineVariant: tokens.border,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: tokens.surface,
      textTheme: AppType.textTheme,
      extensions: [tokens],
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.surface,
        foregroundColor: tokens.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: AppElevation.flat,
      ),
      cardTheme: CardThemeData(
        color: tokens.surfaceVariant,
        surfaceTintColor: Colors.transparent,
        elevation: tokens.elevationCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tokens.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        elevation: tokens.elevationDialog,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      ),
      dividerTheme: DividerThemeData(color: tokens.border),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: tokens.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: tokens.primary, width: 2),
        ),
      ),
    );
  }
}
