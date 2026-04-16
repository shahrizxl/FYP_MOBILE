import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final p1 = TextEditingController();
  final p2 = TextEditingController();

  bool loading = false;
  String? message;
  
  // Toggles for password visibility
  bool _obscureP1 = true;
  bool _obscureP2 = true;

  @override
  void dispose() {
    p1.dispose();
    p2.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    if (loading) return;

    final a = p1.text.trim();
    final b = p2.text.trim();

    if (a.length < 6) {
      setState(() => message = "Password must be at least 6 characters.");
      return;
    }
    if (a != b) {
      setState(() => message = "Passwords do not match.");
      return;
    }

    setState(() {
      loading = true;
      message = null;
    });

    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: a),
      );

      if (!mounted) return;

      setState(() => message = "Password updated successfully. Please log in again.");

      await Supabase.instance.client.auth.signOut();

      if (!mounted) return;

      // Add a slight delay so the user can read the success message
      await Future.delayed(const Duration(seconds: 2));
      
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => message = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => message = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final isSuccess = (message ?? "").startsWith("Password updated");

    InputDecoration _themedInput({
      required String labelText,
      required IconData prefixIcon,
      String? hintText,
      required bool isObscured,
      required VoidCallback onToggleVisibility,
    }) {
      return InputDecoration(
        labelText: labelText,
        hintText: hintText,
        prefixIcon: Icon(prefixIcon, color: cs.primary),
        suffixIcon: IconButton(
          icon: Icon(isObscured ? Icons.visibility_off_outlined : Icons.visibility_outlined),
          color: t.hintColor,
          onPressed: onToggleVisibility,
        ),
        filled: true,
        fillColor: cs.surfaceContainerHighest.withOpacity(0.3),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
      );
    }

    Widget _feedbackBox() {
      if (message == null) return const SizedBox.shrink();
      
      final bgColor = isSuccess ? Colors.green.shade100 : cs.errorContainer;
      final fgColor = isSuccess ? Colors.green.shade800 : cs.onErrorContainer;
      final icon = isSuccess ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded;

      return Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: fgColor, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message!,
                style: TextStyle(color: fgColor, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text("Reset Password", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  onPressed: loading || isSuccess ? null : _update,
                  icon: loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.lock_reset_rounded),
                  label: Text(
                    loading ? "Updating..." : "Update Password",
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: TextButton(
                  onPressed: loading ? null : () => Navigator.pop(context),
                  child: Text(isSuccess ? "Back to Login" : "Cancel", style: TextStyle(color: t.hintColor, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Hero Security Icon
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [cs.primary, cs.tertiary],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: cs.primary.withOpacity(0.3), blurRadius: 20, offset: const Offset(0, 8)),
                        ],
                      ),
                      child: Icon(Icons.lock_person_rounded, size: 56, color: cs.onPrimary),
                    ),
                  ),
                  const SizedBox(height: 24),

                  Text(
                    "Secure Your Account",
                    textAlign: TextAlign.center,
                    style: t.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),

                  Text(
                    "Enter a new password below. For your security, you will be logged out of all devices after updating.",
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Form Card
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: t.dividerColor.withOpacity(0.4)),
                      boxShadow: [
                        BoxShadow(color: t.shadowColor.withOpacity(0.05), blurRadius: 20, offset: const Offset(0, 10)),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _feedbackBox(),

                        Text("New Password", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: cs.onSurface)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: p1,
                          obscureText: _obscureP1,
                          textInputAction: TextInputAction.next,
                          decoration: _themedInput(
                            labelText: "At least 6 characters",
                            prefixIcon: Icons.vpn_key_outlined,
                            isObscured: _obscureP1,
                            onToggleVisibility: () => setState(() => _obscureP1 = !_obscureP1),
                          ),
                        ),
                        
                        const SizedBox(height: 20),
                        
                        Text("Confirm Password", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: cs.onSurface)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: p2,
                          obscureText: _obscureP2,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => loading || isSuccess ? null : _update(),
                          decoration: _themedInput(
                            labelText: "Type it again to verify",
                            prefixIcon: Icons.lock_outline_rounded,
                            isObscured: _obscureP2,
                            onToggleVisibility: () => setState(() => _obscureP2 = !_obscureP2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}