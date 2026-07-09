
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthDeeplinkHandler {
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  void start() {
    _sub = _appLinks.uriLinkStream.listen(
      (uri) async {
        await _handleUri(uri);
      },
      onError: (err) {
        debugPrint("Deeplink stream error: $err");
      },
    );

    _init();
  }

  Future<void> _init() async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        await _handleUri(uri);
      }
    } catch (e) {
      debugPrint("getInitialLink error: $e");
    }
  }

  Future<void> _handleUri(Uri uri) async {
    debugPrint("Deep link received: $uri");

    if (uri.scheme != "com.example.smartbudget") return;
    if (uri.host != "/reset-password") return;

    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      debugPrint("No code found in deep link.");
      return;
    }

    try {
      await Supabase.instance.client.auth.exchangeCodeForSession(code);
      debugPrint("exchangeCodeForSession success (recovery session created).");
    } catch (e) {
      debugPrint("exchangeCodeForSession failed: $e");
    }
  }

  void dispose() {
    _sub?.cancel();
  }
}