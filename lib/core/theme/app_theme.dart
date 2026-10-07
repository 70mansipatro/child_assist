import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Brand palette. Feature gradients give each area of the app its own colour identity
/// (Location is teal, Photos is coral, Documents is blue, Profile is amber, Permissions is violet).
abstract final class AppColors {
  static const primary = Color(0xFF5B4BFF);
  static const primaryDeep = Color(0xFF3B2EC9);
  static const violet = Color(0xFF8B5CF6);
  static const teal = Color(0xFF0FBFA3);
  static const sky = Color(0xFF3B9CFF);
  static const coral = Color(0xFFFF6B6B);
  static const pink = Color(0xFFF15BB5);
  static const amber = Color(0xFFFFA62B);
  static const orange = Color(0xFFFF7A45);
  static const success = Color(0xFF16B67F);
  static const warning = Color(0xFFF2A60D);
  static const danger = Color(0xFFE5484D);

  static const ink = Color(0xFF15162B);
  static const inkMuted = Color(0xFF6B6F8E);
  static const lightBackground = Color(0xFFF5F6FB);
  static const darkBackground = Color(0xFF0D0E19);
  static const darkSurface = Color(0xFF171928);
  static const darkSurfaceHigh = Color(0xFF212438);
}

abstract final class AppGradients {
  static const brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6A5CFF), Color(0xFF4433D6)],
  );
  static const _heroColors = [Color(0xFF7B61FF), Color(0xFF5B4BFF), Color(0xFF3B2EC9)];
  static const hero = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: _heroColors,
  );

  /// The header's colours laid out left to right, for the wide, short bottom navigation bar.
  static const navigationBar = LinearGradient(colors: _heroColors);
  static const location = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF14C9A9), Color(0xFF2E8FFF)],
  );
  static const photos = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF15BB5), Color(0xFFFF7A59)],
  );
  static const documents = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF38B6FF), Color(0xFF2F5BEA)],
  );
  static const profile = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFFB443), Color(0xFFFF7A45)],
  );
  static const permissions = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF9B6BFF), Color(0xFF5B4BFF)],
  );
  static const notifications = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF3B9CFF), Color(0xFF5B4BFF)],
  );
  static const microphone = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF6B6B), Color(0xFFF15BB5)],
  );
  static const danger = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF6B6B), Color(0xFFE5484D)],
  );
}

/// Spacing and radius tokens, so every screen lines up on the same rhythm.
abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  static const radiusSm = 12.0;
  static const radius = 16.0;
  static const radiusLg = 22.0;
  static const radiusXl = 32.0;
}

abstract final class AppTheme {
  static const fontFamily = 'Poppins';

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final seeded = ColorScheme.fromSeed(seedColor: AppColors.primary, brightness: brightness);
    final scheme = seeded.copyWith(
      primary: isDark ? const Color(0xFF8F84FF) : AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.teal,
      tertiary: AppColors.coral,
      error: AppColors.danger,
      surface: isDark ? AppColors.darkSurface : Colors.white,
      onSurface: isDark ? const Color(0xFFF1F2F8) : AppColors.ink,
      onSurfaceVariant: isDark ? const Color(0xFFA3A7C2) : AppColors.inkMuted,
      surfaceContainerLowest: isDark ? AppColors.darkBackground : Colors.white,
      surfaceContainerLow: isDark ? const Color(0xFF14162A) : const Color(0xFFF9F9FD),
      surfaceContainer: isDark ? AppColors.darkSurface : const Color(0xFFF1F2F9),
      surfaceContainerHigh: isDark ? AppColors.darkSurfaceHigh : const Color(0xFFECEDF6),
      surfaceContainerHighest: isDark ? const Color(0xFF2A2D44) : const Color(0xFFE6E7F2),
      outline: isDark ? const Color(0xFF4A4E6B) : const Color(0xFFC9CBDD),
      outlineVariant: isDark ? const Color(0xFF2C2F47) : const Color(0xFFE6E7F0),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: fontFamily,
    );
    final text = base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.1),
      labelMedium: base.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.5),
      bodySmall: base.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
    );

    const buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(AppSpacing.radius)),
    );
    const buttonText = TextStyle(fontFamily: fontFamily, fontSize: 15, fontWeight: FontWeight.w600);
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radius),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );

    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: isDark ? AppColors.darkBackground : AppColors.lightBackground,
      splashFactory: InkSparkle.splashFactory,
      // Every screen's heading uses the brand purple; screens paint [AppBarGradient] over it.
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.primary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        foregroundColor: Colors.white,
        titleTextStyle: text.titleLarge?.copyWith(color: Colors.white, fontSize: 20),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      actionIconTheme: ActionIconThemeData(
        backButtonIconBuilder: (_) => const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.radiusLg)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 50),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: buttonShape,
          textStyle: buttonText,
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.7)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: buttonShape,
          textStyle: buttonText,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppSpacing.radiusSm)),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? AppColors.darkSurfaceHigh : const Color(0xFFF4F5FA),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: fieldBorder.copyWith(borderSide: BorderSide(color: scheme.primary, width: 1.6)),
        errorBorder: fieldBorder.copyWith(borderSide: BorderSide(color: scheme.error)),
        focusedErrorBorder: fieldBorder.copyWith(borderSide: BorderSide(color: scheme.error, width: 1.6)),
        prefixIconColor: WidgetStateColor.resolveWith((states) =>
            states.contains(WidgetState.focused) ? scheme.primary : scheme.onSurfaceVariant),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w500),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith((states) => TextStyle(
              color: states.contains(WidgetState.error) ? scheme.error : scheme.primary,
              fontWeight: FontWeight.w600,
            )),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.8)),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surface,
        labelStyle: TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w500, color: scheme.onSurface),
        iconTheme: IconThemeData(color: scheme.primary, size: 18),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
        contentTextStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? AppColors.darkSurfaceHigh : AppColors.ink,
        contentTextStyle: const TextStyle(fontFamily: fontFamily, color: Colors.white, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.radius)),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.primary.withValues(alpha: 0.12),
        circularTrackColor: Colors.transparent,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.radius)),
        iconColor: scheme.primary,
      ),
      datePickerTheme: DatePickerThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        surfaceTintColor: Colors.transparent,
        rangeSelectionBackgroundColor: scheme.primary.withValues(alpha: 0.12),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      }),
    );
  }

  /// Soft, layered shadow used under cards in light mode. Dark mode relies on surface tone.
  static List<BoxShadow> softShadow(BuildContext context, {Color? tint, double strength = 1}) {
    if (Theme.of(context).brightness == Brightness.dark) return const [];
    final color = tint ?? const Color(0xFF2A2B5E);
    return [
      BoxShadow(
        color: color.withValues(alpha: 0.06 * strength),
        blurRadius: 24,
        offset: const Offset(0, 10),
      ),
      BoxShadow(
        color: color.withValues(alpha: 0.04 * strength),
        blurRadius: 4,
        offset: const Offset(0, 1),
      ),
    ];
  }

  /// A coloured glow under gradient elements (buttons, icon badges).
  static List<BoxShadow> glow(Color color, {double strength = 1}) => [
        BoxShadow(
          color: color.withValues(alpha: 0.35 * strength),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
      ];
}
