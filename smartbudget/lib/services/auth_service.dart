import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase_config.dart';

class AuthService {
  Future<void> logout() async {
    await SupabaseConfig.client.auth.signOut();
  }

  Future<void> login(String email, String password) async {
    try {
      final res = await SupabaseConfig.client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (res.user == null) {
        throw Exception("Login failed. Please try again.");
      }

      // ✅ block inactive users
      await _ensureActiveAccount();

    } on AuthException catch (e) {
      throw Exception(_friendlyAuthError(e));
    } catch (e) {
      throw Exception(_friendlyGenericError(e));
    }
  }

  Future<void> signUp(String email, String password) async {
    try {
      final res = await SupabaseConfig.client.auth.signUp(
        email: email,
        password: password,
      );

      if (res.user == null) {
        throw Exception("Signup failed. Please try again.");
      }

      // ✅ if signup auto-logged in (confirmation OFF), force logout
      if (res.session != null) {
        await SupabaseConfig.client.auth.signOut();
      }

      // ✅ DO NOT call _ensureActiveAccount() here
      // user will login later, then checks happen
      return;

    } on AuthException catch (e) {
      throw Exception(_friendlyAuthError(e));
    } catch (e) {
      throw Exception(_friendlyGenericError(e));
    }
  }

  // ----------------------------
  // ACTIVE ACCOUNT CHECK
  // ----------------------------
  Future<void> _ensureActiveAccount() async {
    final user = SupabaseConfig.client.auth.currentUser;
    if (user == null) return;

    Map<String, dynamic>? profile;

    // ✅ retry to allow trigger to insert profiles
    for (int attempt = 0; attempt < 6; attempt++) {
      profile = await SupabaseConfig.client
          .from('profiles')
          .select('is_active')
          .eq('id', user.id)
          .maybeSingle();

      if (profile != null) break;
      await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
    }

    if (profile == null) {
      await SupabaseConfig.client.auth.signOut();
      throw Exception("Profile not found. Please contact admin.");
    }

    final isActive = (profile['is_active'] as bool?) ?? true;

    if (!isActive) {
      await SupabaseConfig.client.auth.signOut();
      throw Exception("Your account has been deactivated. Please contact admin.");
    }
  }

  // ----------------------------
  // ERROR MAPPING (MOST IMPORTANT)
  // ----------------------------
  String _friendlyAuthError(AuthException e) {
    final msg = (e.message).toLowerCase();

    // Common Supabase auth errors
    if (msg.contains("invalid login credentials") ||
        msg.contains("invalid credentials")) {
      return "Wrong email or password.";
    }

    if (msg.contains("email not confirmed") ||
        msg.contains("confirm your email")) {
      return "Please verify your email first (check your inbox).";
    }

    if (msg.contains("user already registered") ||
        msg.contains("already been registered")) {
      return "This email is already registered. Try logging in.";
    }

    if (msg.contains("password should be at least")) {
      return "Password is too short. Please use a stronger password.";
    }

    if (msg.contains("rate limit") ||
        msg.contains("too many requests")) {
      return "Too many attempts. Please wait a moment and try again.";
    }

    // fallback
    return e.message;
  }

  String _friendlyGenericError(Object e) {
    final s = e.toString().toLowerCase();

    if (s.contains("socketexception") ||
        s.contains("failed host lookup") ||
        s.contains("network")) {
      return "No internet connection. Please check your network.";
    }

    return e.toString().replaceFirst("Exception: ", "");
  }
}