import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final oldCtrl = TextEditingController();
  final newCtrl = TextEditingController();
  final confirmCtrl = TextEditingController();

  bool loading = false;
  String? error;

  // Toggles for password visibility
  bool _obscureOld = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  SupabaseClient get supabase => Supabase.instance.client;

  @override
  void dispose() {
    oldCtrl.dispose();
    newCtrl.dispose();
    confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveNewPassword() async {
    if (loading) return;

    final user = supabase.auth.currentUser;
    final email = user?.email?.trim();

    if (email == null || email.isEmpty) {
      setState(() => error = "No email found for this account.");
      return;
    }

    final oldPass = oldCtrl.text;
    final newPass = newCtrl.text;
    final confirm = confirmCtrl.text;

    if (oldPass.isEmpty) {
      setState(() => error = "Please enter your current password.");
      return;
    }

    if (newPass.length < 6) {
      setState(() => error = "Your new password must be at least 6 characters.");
      return;
    }

    if (newPass != confirm) {
      setState(() => error = "New passwords do not match.");
      return;
    }

    setState(() {
      loading = true;
      error = null;
    });

    try {
      // Step 1: verify old password by re-auth
      await supabase.auth.signInWithPassword(
        email: email,
        password: oldPass,
      );

      // Step 2: update password
      await supabase.auth.updateUser(
        UserAttributes(password: newPass),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.white),
              SizedBox(width: 8),
              Text("Password updated successfully"),
            ],
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );

      Navigator.pop(context);
    } on AuthException catch (e) {
      setState(() => error = e.message);
    } catch (e) {
      setState(() => error = "Unexpected error: $e");
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    InputDecoration _themedInput({
      required String labelText,
      required IconData prefixIcon,
      required bool isObscured,
      required VoidCallback onToggleVisibility,
    }) {
      return InputDecoration(
        labelText: labelText,
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

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text("Security", style: TextStyle(fontWeight: FontWeight.bold)),
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
                  onPressed: loading ? null : _saveNewPassword,
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
                  child: Text("Cancel", style: TextStyle(color: t.hintColor, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 20),
            
            // Hero Security Icon
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withOpacity(0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.shield_rounded, size: 48, color: cs.primary),
            ),
            const SizedBox(height: 16),
            Text(
              "Reset your password",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: cs.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              "Ensure your account stays secure by using a strong, unique password.",
              textAlign: TextAlign.center,
              style: TextStyle(color: t.hintColor, height: 1.4),
            ),
            const SizedBox(height: 32),

            // Error State
            if (error != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded, color: cs.error),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        error!,
                        style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],

            // Input Form Card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: t.dividerColor.withOpacity(0.4)),
                boxShadow: [
                  BoxShadow(color: t.shadowColor.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4)),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Current Password", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: cs.onSurface)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: oldCtrl,
                    obscureText: _obscureOld,
                    textInputAction: TextInputAction.next,
                    decoration: _themedInput(
                      labelText: "Enter current password",
                      prefixIcon: Icons.vpn_key_outlined,
                      isObscured: _obscureOld,
                      onToggleVisibility: () => setState(() => _obscureOld = !_obscureOld),
                    ),
                  ),
                  
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16.0),
                    child: Divider(),
                  ),
                  
                  Text("New Password", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: cs.onSurface)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: newCtrl,
                    obscureText: _obscureNew,
                    textInputAction: TextInputAction.next,
                    decoration: _themedInput(
                      labelText: "At least 6 characters",
                      prefixIcon: Icons.lock_outline_rounded,
                      isObscured: _obscureNew,
                      onToggleVisibility: () => setState(() => _obscureNew = !_obscureNew),
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  TextField(
                    controller: confirmCtrl,
                    obscureText: _obscureConfirm,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _saveNewPassword(),
                    decoration: _themedInput(
                      labelText: "Confirm new password",
                      prefixIcon: Icons.lock_outline_rounded,
                      isObscured: _obscureConfirm,
                      onToggleVisibility: () => setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}