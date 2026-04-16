import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemePrefs {
  static const _kThemeMode = "theme_mode"; // "system" | "light" | "dark"

  static Future<ThemeMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kThemeMode) ?? "system";
    switch (v) {
      case "light":
        return ThemeMode.light;
      case "dark":
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static Future<void> save(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    final v = switch (mode) {
      ThemeMode.light => "light",
      ThemeMode.dark => "dark",
      _ => "system",
    };
    await prefs.setString(_kThemeMode, v);
  }
}