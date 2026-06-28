import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../pages/login_page.dart';
import '../pages/admin_page.dart';
import '../pages/user_shell.dart';
import '../pages/reset_password_page.dart';
import 'auth_service.dart';
import 'auth_deeplink_handler.dart';
import 'notification_service.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  String? _lastAuthError;

  late final AuthDeeplinkHandler _deeplinks;
  StreamSubscription<AuthState>? _sub;

  bool _showingRecovery = false;
  bool _loggingOut = false;

  // ✅ Prevent repeated notification scheduling
  bool _notificationsScheduled = false;

  Future<Map<String, dynamic>?> _getProfile() async {
    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) return null;

    return await Supabase.instance.client
        .from('profiles')
        .select('role, is_active')
        .eq('id', user.id)
        .maybeSingle();
  }

  void _logoutWithMessage(String msg) {
    if (_loggingOut) return;

    _loggingOut = true;
    _lastAuthError = msg;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await AuthService().logout();
      } finally {
        if (mounted) {
          setState(() {});
        }

        _loggingOut = false;
      }
    });
  }

  @override
  void initState() {
    super.initState();

    // Start deeplink handler
    _deeplinks = AuthDeeplinkHandler();
    _deeplinks.start();

    // Listen for password recovery
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (!mounted) return;

      if (data.event == AuthChangeEvent.passwordRecovery) {
        if (_showingRecovery) return;

        _showingRecovery = true;

        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;

          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const ResetPasswordPage(),
            ),
          );

          _showingRecovery = false;

          if (mounted) {
            setState(() {});
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _deeplinks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session =
            Supabase.instance.client.auth.currentSession;

        final event = snapshot.data?.event;

        if (snapshot.connectionState ==
            ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        // During password recovery
        if (event == AuthChangeEvent.passwordRecovery) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        // Not logged in
        if (session == null) {
          // ✅ Reset scheduling for next login
          _notificationsScheduled = false;

          final msg = _lastAuthError;
          _lastAuthError = null;

          return LoginPage(
            initialError: msg,
          );
        }

        // Logged in → load profile
        return FutureBuilder<Map<String, dynamic>?>(
          future: _getProfile(),
          builder: (context, profSnap) {
            if (profSnap.connectionState ==
                ConnectionState.waiting) {
              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(),
                ),
              );
            }

            if (profSnap.hasError) {
              _logoutWithMessage(
                "Failed to load profile. Please login again.",
              );

              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(),
                ),
              );
            }

            final profile = profSnap.data;

            if (profile == null) {
              _logoutWithMessage(
                "Profile not found. Please sign in.",
              );

              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(),
                ),
              );
            }

            final role =
                profile['role']?.toString() ?? 'user';

            final isActive =
                (profile['is_active'] as bool?) ?? true;

            if (!isActive) {
              _logoutWithMessage(
                "Your account has been deactivated. Please contact admin.",
              );

              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(),
                ),
              );
            }

            // ✅ Schedule notifications once per login
            if (!_notificationsScheduled) {
              _notificationsScheduled = true;

              WidgetsBinding.instance
                  .addPostFrameCallback((_) async {
                try {
                  await NotificationService.instance
                      .ensureScheduled(
                    salaryDay: 25,
                    salaryHour: 20,
                    monthStartHour: 9,
                  );

                  await NotificationService.instance
                     .restorePlannedPayments();
                } catch (e) {
                  debugPrint(
                    "Notification schedule error: $e",
                  );
                }
              });
            }

            return role == 'admin'
                ? const AdminPage()
                : const UserShell();
          },
        );
      },
    );
  }
}