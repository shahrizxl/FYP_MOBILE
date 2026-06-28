// lib/main.dart

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_theme.dart';
import 'supabase_config.dart';
import 'services/auth_gate.dart';
import 'services/notification_service.dart';
import 'theme.dart';

Future<void> main() async {
  // 1. Ensure Flutter bindings are ready
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Initialize Supabase safely so network drops don't crash the app
  try {
    await Supabase.initialize(
      url: SupabaseConfig.supabaseUrl,
      anonKey: SupabaseConfig.supabaseAnonKey,
    );
  } catch (e) {
    debugPrint("Supabase Init Error: $e");
  }

  // 3. Initialize notifications only
  if (!kIsWeb) {
    try {
      await NotificationService.instance.init();
    } catch (e) {
      debugPrint("Notification Init Error: $e");
    }
  }
    // 4. Paint the UI immediately
    runApp(const MyApp());
  }

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  /// Allows calling:
  /// MyApp.of(context).setThemeMode(...)
  static _MyAppState of(BuildContext context) {
    final state = context.findAncestorStateOfType<_MyAppState>();
    assert(
      state != null,
      "MyApp state not found. Make sure you're under MyApp.",
    );
    return state!;
  }

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _mode = ThemeMode.system;

  ThemeMode get themeMode => _mode;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  /// Loads saved theme safely
  Future<void> _loadTheme() async {
    final saved = await ThemePrefs.load();
    if (!mounted) return;

    setState(() => _mode = saved);
  }

  /// Safe theme changer (NOT async)
  void setThemeMode(ThemeMode mode) {
    if (_mode == mode) return;

    setState(() => _mode = mode);

    // Fire-and-forget save
    ThemePrefs.save(mode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartBudget',
      debugShowCheckedModeBanner: false,

      // Your themes
      theme: AppTheme.classy(),
      darkTheme: AppTheme.classyDark(),

      // Global theme controller
      themeMode: _mode,

      // Prevents large font scaling breaking UI
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.0),
          ),
          child: child!,
        );
      },

      home: const AuthGate(),
    );
  }
}