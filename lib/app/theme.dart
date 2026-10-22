import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Spacing scale (4-pt grid).
abstract final class Gaps {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Horizontal page gutter.
  static const double page = 20;
}

abstract final class Radii {
  static const double s = 10;
  static const double m = 14;
  static const double l = 20;
  static const double xl = 28;
}

const _seed = Color(0xFF2E5BDA);

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
  );
  // Neutral, slightly cool surfaces for a calm utility look.
  final scheme = base.copyWith(
    surface: isDark ? const Color(0xFF111318) : const Color(0xFFF8F9FC),
    surfaceContainerLowest: isDark ? const Color(0xFF0C0E12) : Colors.white,
    surfaceContainerLow: isDark ? const Color(0xFF181B21) : const Color(0xFFF2F4F8),
    surfaceContainer: isDark ? const Color(0xFF1D2027) : const Color(0xFFECEEF3),
    surfaceContainerHigh: isDark ? const Color(0xFF23272F) : const Color(0xFFE6E9EF),
    surfaceContainerHighest: isDark ? const Color(0xFF2B2F38) : const Color(0xFFDFE3EA),
    outlineVariant: isDark ? const Color(0xFF353A44) : const Color(0xFFDADEE6),
  );

  final text = _textTheme(scheme);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: 'Inter',
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      titleSpacing: Gaps.page,
      titleTextStyle: text.titleLarge,
      systemOverlayStyle: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.secondaryContainer,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelMedium!.copyWith(
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.l),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: isDark ? 0.6 : 0.8)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.m)),
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.m)),
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.s)),
        textStyle: text.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.m),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.m),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.m),
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.m),
        borderSide: BorderSide(color: scheme.error),
      ),
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      constraints: const BoxConstraints(minHeight: 52),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl))),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
      textStyle: WidgetStatePropertyAll(text.bodyLarge),
      hintStyle: WidgetStatePropertyAll(text.bodyLarge!.copyWith(color: scheme.onSurfaceVariant)),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.s)),
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: text.labelLarge!.copyWith(fontWeight: FontWeight.w500),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(48, 44),
        textStyle: text.labelLarge!.copyWith(fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.m)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: Gaps.page, vertical: 2),
      minVerticalPadding: 10,
      titleTextStyle: text.bodyLarge!.copyWith(fontWeight: FontWeight.w500, color: scheme.onSurface),
      subtitleTextStyle: text.bodyMedium!.copyWith(color: scheme.onSurfaceVariant),
      iconColor: scheme.onSurfaceVariant,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.6), space: 1, thickness: 1),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
      titleTextStyle: text.titleLarge,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.m)),
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: text.bodyMedium!.copyWith(color: scheme.onInverseSurface),
    ),
    sliderTheme: SliderThemeData(
      showValueIndicator: ShowValueIndicator.onDrag,
      trackHeight: 4,
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(4),
    ),
    switchTheme: SwitchThemeData(
      thumbIcon: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? const Icon(Icons.check_rounded, size: 16) : null,
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: PredictiveBackPageTransitionsBuilder()},
    ),
  );
}

TextTheme _textTheme(ColorScheme s) {
  const family = 'Inter';
  TextStyle style(double size, FontWeight w, {double height = 1.3, double ls = 0, Color? color}) => TextStyle(
    fontFamily: family,
    fontSize: size,
    fontWeight: w,
    height: height,
    letterSpacing: ls,
    color: color ?? s.onSurface,
  );
  return TextTheme(
    displaySmall: style(32, FontWeight.w700, height: 1.15, ls: -0.8),
    headlineMedium: style(28, FontWeight.w700, height: 1.2, ls: -0.6),
    headlineSmall: style(24, FontWeight.w700, height: 1.25, ls: -0.4),
    titleLarge: style(20, FontWeight.w600, height: 1.3, ls: -0.2),
    titleMedium: style(16, FontWeight.w600, height: 1.35, ls: -0.1),
    titleSmall: style(14, FontWeight.w600, height: 1.4),
    bodyLarge: style(16, FontWeight.w400, height: 1.45),
    bodyMedium: style(14, FontWeight.w400, height: 1.45, color: s.onSurface),
    bodySmall: style(12.5, FontWeight.w400, height: 1.4, color: s.onSurfaceVariant),
    labelLarge: style(14.5, FontWeight.w600, height: 1.2),
    labelMedium: style(12.5, FontWeight.w500, height: 1.2, ls: 0.1),
    labelSmall: style(11.5, FontWeight.w500, height: 1.2, ls: 0.2, color: s.onSurfaceVariant),
  );
}
