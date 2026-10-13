// Design tokens from docs/design/ui-spec.md (sampled from the mockups).

import 'package:flutter/material.dart';

abstract final class AppTokens {
  static const background = Color(0xFFFAF6F1);
  static const card = Colors.white;
  static const gradientStart = Color(0xFFFC494C);
  static const gradientEnd = Color(0xFFFA662E);
  static const primary = Color(0xFFEA3B48);
  static const pinkBg = Color(0xFFFFDCD7);
  static const beigeBg = Color(0xFFF3E9E1);
  static const textPrimary = Color(0xFF1E130F);
  static const textSecondary = Color(0xFFA89B92);
  static const platformXhs = Color(0xFFEA1C42);
  static const platformIg = Color(0xFFCE35A8);

  static const darkBackground = Color(0xFF1A1412);
  static const darkCard = Color(0xFF26201C);
  static const darkPrimary = Color(0xFFF26A75);
  static const darkPinkBg = Color(0xFF4A2622);
  static const darkBeigeBg = Color(0xFF33291F);
  static const darkTextPrimary = Color(0xFFF5ECE6);
  static const darkTextSecondary = Color(0xFF8D7F76);

  static const mainGradient = LinearGradient(
    colors: [gradientStart, gradientEnd],
  );

  static const cardShadow = [
    BoxShadow(color: Color(0x14000000), blurRadius: 16, offset: Offset(0, 4)),
  ];

  static const cardRadius = 24.0;
  static const thumbRadius = 16.0;
}

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppTokens.primary,
    brightness: Brightness.light,
  ).copyWith(primary: AppTokens.primary, surface: AppTokens.card);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: AppTokens.background,
    useMaterial3: true,
    cardTheme: const CardThemeData(
      color: AppTokens.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppTokens.cardRadius)),
      ),
    ),
  );
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppTokens.primary,
    brightness: Brightness.dark,
  ).copyWith(primary: AppTokens.darkPrimary, surface: AppTokens.darkCard);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: AppTokens.darkBackground,
    useMaterial3: true,
    cardTheme: const CardThemeData(
      color: AppTokens.darkCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppTokens.cardRadius)),
      ),
    ),
  );
}

/// Pink/beige secondary backgrounds, dark-mode aware.
class SecondaryBg {
  static Color pink(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? AppTokens.darkPinkBg
      : AppTokens.pinkBg;

  static Color beige(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? AppTokens.darkBeigeBg
      : AppTokens.beigeBg;
}
