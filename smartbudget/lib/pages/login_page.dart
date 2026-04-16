import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/auth_service.dart';

class LoginPage extends StatefulWidget {
  final String? initialError;
  const LoginPage({super.key, this.initialError});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();

  bool isLogin = true;
  bool loading = false;
  String? error;
  
  bool _obscurePass = true;

  @override
  void initState() {
    super.initState();
    error = widget.initialError;
  }

  @override
  void dispose() {
    emailCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }

  InputDecoration _themedInput({
    required BuildContext context,
    required String labelText,
    required IconData prefixIcon,
    Widget? suffixIcon,
    String? hintText,
  }) {
    final cs = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixIcon: Icon(prefixIcon, color: cs.primary),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: cs.surfaceContainerHighest.withOpacity(0.3),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: cs.primary, width: 2),
      ),
    );
  }

  Widget _errorBox(String msg) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: cs.error, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(fontWeight: FontWeight.bold, color: cs.onErrorContainer),
              textAlign: TextAlign.left,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _forgotPassword() async {
    if (loading) return;

    final tmpCtrl = TextEditingController(text: emailCtrl.text.trim());
    final cs = Theme.of(context).colorScheme;

    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text("Reset Password", style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Enter your email address and we'll send you a link to reset your password."),
            const SizedBox(height: 16),
            TextField(
              controller: tmpCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: _themedInput(
                context: context,
                labelText: "Email",
                prefixIcon: Icons.email_outlined,
                hintText: "you@example.com",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, tmpCtrl.text.trim()),
            child: const Text("Send Link"),
          ),
        ],
      ),
    );

    if (email == null || email.isEmpty) return;

    setState(() {
      loading = true;
      error = null;
    });

    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        // ✅ FIXED: This matches your AndroidManifest.xml deep link exactly
        redirectTo: 'com.example.smartbudget://reset-password',
      );

      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.mark_email_read_rounded, color: Colors.white),
              SizedBox(width: 8),
              Expanded(child: Text("Reset link sent! Please check your email inbox and spam folder.")),
            ],
          ),
          backgroundColor: cs.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst("Exception: ", "");
      setState(() => error = msg);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> submit() async {
    if (loading) return;

    setState(() {
      loading = true;
      error = null;
    });

    try {
      if (isLogin) {
        await AuthService().login(
          emailCtrl.text.trim(),
          passCtrl.text,
        );
        return;
      } else {
        await AuthService().signUp(
          emailCtrl.text.trim(),
          passCtrl.text,
        );

        if (!mounted) return;

        final session = Supabase.instance.client.auth.currentSession;

        setState(() {
          isLogin = true;
          error = null; // ✅ FIXED: Clears any red error box
        });

        // ✅ FIXED: Shows a green success snackbar instead of an error box
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_outline, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(session == null
                      ? "Account created successfully. Please verify your email."
                      : "Account created. Please log in."),
                ),
              ],
            ),
            backgroundColor: Colors.green.shade700,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst("Exception: ", "");
      setState(() => error = msg);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo Hero
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
                      child: Icon(Icons.account_balance_wallet_rounded, size: 56, color: cs.onPrimary),
                    ),
                  ),
                  const SizedBox(height: 24),

                  Text(
                    "SmartBudget",
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),

                  Text(
                    "Manage your money smarter.",
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Main Form Card
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: theme.dividerColor.withOpacity(0.4)),
                      boxShadow: [
                        BoxShadow(color: theme.shadowColor.withOpacity(0.05), blurRadius: 20, offset: const Offset(0, 10)),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          isLogin ? "Welcome back" : "Create your account",
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 20),

                        TextField(
                          controller: emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          decoration: _themedInput(
                            context: context,
                            labelText: "Email",
                            prefixIcon: Icons.email_outlined,
                          ),
                        ),
                        const SizedBox(height: 16),

                        TextField(
                          controller: passCtrl,
                          obscureText: _obscurePass,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => submit(),
                          decoration: _themedInput(
                            context: context,
                            labelText: "Password",
                            prefixIcon: Icons.lock_outline_rounded,
                            suffixIcon: IconButton(
                              icon: Icon(_obscurePass ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                              color: theme.hintColor,
                              onPressed: () => setState(() => _obscurePass = !_obscurePass),
                            ),
                          ),
                        ),

                        if (isLogin)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: loading ? null : _forgotPassword,
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                minimumSize: Size.zero,
                              ),
                              child: Text(
                                "Forgot password?",
                                style: TextStyle(fontWeight: FontWeight.bold, color: cs.primary),
                              ),
                            ),
                          )
                        else
                          const SizedBox(height: 16),

                        if (error != null) ...[
                          const SizedBox(height: 8),
                          _errorBox(error!),
                          const SizedBox(height: 16),
                        ],

                        const SizedBox(height: 12),

                        SizedBox(
                          height: 56,
                          child: FilledButton(
                            onPressed: loading ? null : submit,
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                            child: loading
                                ? const SizedBox(
                                    height: 24,
                                    width: 24,
                                    child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                                  )
                                : Text(
                                    isLogin ? "Login" : "Create Account",
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Toggle Login/Signup
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        isLogin ? "Don't have an account?" : "Already have an account?",
                        style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w500),
                      ),
                      TextButton(
                        onPressed: loading ? null : () => setState(() {
                          isLogin = !isLogin;
                          error = null;
                        }),
                        child: Text(
                          isLogin ? "Sign up" : "Log in",
                          style: TextStyle(fontWeight: FontWeight.bold, color: cs.primary),
                        ),
                      ),
                    ],
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