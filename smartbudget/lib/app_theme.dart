import 'package:flutter/material.dart';

class AppTheme {
  // =========================
  // Light tokens
  // =========================
  static const background = Color(0xFFF6F6F7);
  static const card = Color(0xFFFFFFFF);
  static const border = Color(0xFFE5E5EA);
  static const textPrimary = Color(0xFF111111);
  static const textSecondary = Color(0xFF6B6B70);
  static const danger = Color(0xFFE5484D);

  static const radiusCard = 24.0;
  static const radiusControl = 16.0;

  // =========================
  // Dark tokens
  // =========================
  static const backgroundDark = Color(0xFF0E0F12);
  static const cardDark = Color(0xFF14161B);
  static const borderDark = Color(0xFF2A2D36);
  static const textPrimaryDark = Color(0xFFEDEEF2);
  static const textSecondaryDark = Color(0xFFB7BBC7);
  static const dangerDark = Color(0xFFF97066);

  // =========================
  // Light theme
  // =========================
  static ThemeData classy() {
    // ✅ Material 3 prefers these roles:
    // - surface = card surfaces
    // - background/scaffoldBackgroundColor = page background
    // - onSurface = text on cards
    final cs = ColorScheme.fromSeed(
      seedColor: textPrimary,
      brightness: Brightness.light,
    ).copyWith(
      background: background,
      surface: card,
      onSurface: textPrimary,
      primary: textPrimary,
      onPrimary: Colors.white,
      secondary: textSecondary,
      onSecondary: Colors.white,
      outline: border,
      error: danger,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: cs,
      scaffoldBackgroundColor: background,

      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent, // ✅ prevents M3 tinting
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
      ),

      cardTheme: const CardThemeData(
        color: card,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusCard)),
          side: BorderSide(color: border),
        ),
      ),

      dividerTheme: const DividerThemeData(color: border, thickness: 1),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: textPrimary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusControl),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: const BorderSide(color: border),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusControl),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),

      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFFF1F1F3),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusControl)),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusControl)),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusControl)),
          borderSide: BorderSide(color: textPrimary, width: 1.2),
        ),
      ),

      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: textPrimary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: StadiumBorder(),
      ),

      listTileTheme: const ListTileThemeData(
        iconColor: textPrimary,
        textColor: textPrimary,
      ),

      textTheme: const TextTheme().apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
    );
  }

  // =========================
  // Dark theme
  // =========================
  static ThemeData classyDark() {
    final cs = ColorScheme.fromSeed(
      seedColor: textPrimaryDark,
      brightness: Brightness.dark,
    ).copyWith(
      background: backgroundDark,
      surface: cardDark,
      onSurface: textPrimaryDark,
      primary: textPrimaryDark,
      onPrimary: backgroundDark,
      secondary: textSecondaryDark,
      onSecondary: backgroundDark,
      outline: borderDark,
      error: dangerDark,
      onError: backgroundDark,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: cs,
      scaffoldBackgroundColor: backgroundDark,

      appBarTheme: const AppBarTheme(
        backgroundColor: backgroundDark,
        surfaceTintColor: Colors.transparent,
        foregroundColor: textPrimaryDark,
        elevation: 0,
        centerTitle: false,
      ),

      cardTheme: const CardThemeData(
        color: cardDark,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusCard)),
          side: BorderSide(color: borderDark),
        ),
      ),

      dividerTheme: const DividerThemeData(color: borderDark, thickness: 1),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: textPrimaryDark,
          foregroundColor: backgroundDark,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusControl),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimaryDark,
          side: const BorderSide(color: borderDark),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusControl),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),

      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF1B1E25),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusControl)),
          borderSide: BorderSide(color: borderDark),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusControl)),
          borderSide: BorderSide(color: borderDark),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusControl)),
          borderSide: BorderSide(color: textPrimaryDark, width: 1.2),
        ),
      ),

      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: textPrimaryDark,
        foregroundColor: backgroundDark,
        elevation: 0,
        shape: StadiumBorder(),
      ),

      listTileTheme: const ListTileThemeData(
        iconColor: textPrimaryDark,
        textColor: textPrimaryDark,
      ),

      textTheme: const TextTheme().apply(
        bodyColor: textPrimaryDark,
        displayColor: textPrimaryDark,
      ),
    );
  }
}