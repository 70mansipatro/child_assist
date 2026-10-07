import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/widgets/widgets.dart';
import '../services/auth_service.dart';
import '../widgets/auth_widgets.dart';
import 'forgot_password_screen.dart';
import 'register_screen.dart';
import 'verify_email_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.authService});

  final AuthService authService;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  bool _googleBusy = false;
  bool _obscure = true;
  String? _error;
  String? _notice;

  bool get _busy => _submitting || _googleBusy;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
      _notice = null;
    });
    try {
      // On success AuthService notifies listeners and the app switches to Home.
      await widget.authService.login(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    } on EmailNotVerifiedException catch (e) {
      if (mounted) setState(() => _submitting = false);
      await _openVerification(
        VerifyEmailScreen(
          authService: widget.authService,
          email: e.email.toLowerCase(),
          notice: '${e.message} Enter the latest code we emailed you.',
        ),
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Opens Register or Verify Email. Both end with the verified email when verification succeeds;
  /// the user then logs in here with it filled in.
  Future<void> _openVerification(Widget screen) async {
    final verified = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => screen));
    if (verified == null || !mounted) return;
    setState(() {
      _emailController.text = verified;
      _error = null;
      _notice = 'Email verified successfully. Log in to continue.';
    });
  }

  /// Opens Forgot Password. It ends with the email once the password has been reset; the user then
  /// logs in here with the new password. No session is started by the reset itself.
  Future<void> _openForgotPassword() async {
    final email = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => ForgotPasswordScreen(
        authService: widget.authService,
        initialEmail: _emailController.text.trim(),
      ),
    ));
    if (email == null || !mounted) return;
    setState(() {
      _emailController.text = email;
      _passwordController.clear();
      _error = null;
      _notice = 'Password reset successfully. Please log in with your new password.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: AuthBackdrop(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AuthBrand(subtitle: 'Welcome back! Sign in to continue.'),
              const SizedBox(height: 22),
              FadeSlideIn(
                index: 1,
                child: AppCard(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Log in', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _emailController,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.next,
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Please enter your email' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _passwordController,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: PasswordVisibilityToggle(
                            obscured: _obscure,
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _busy ? null : _submit(),
                        validator: (v) =>
                            (v == null || v.isEmpty) ? 'Please enter your password' : null,
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const ValueKey('forgot-password'),
                          onPressed: _busy ? null : _openForgotPassword,
                          child: const Text('Forgot Password?', style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ),
                      AuthError(message: _error),
                      AuthError(message: _notice, tone: BannerTone.success),
                      const SizedBox(height: 10),
                      GradientButton(
                        onPressed: _busy ? null : _submit,
                        label: _submitting ? const ButtonSpinner() : const Text('Log in'),
                      ),
                      ContinueWithGoogle(
                        authService: widget.authService,
                        enabled: !_submitting,
                        onBusyChanged: (busy) {
                          if (mounted) setState(() => _googleBusy = busy);
                        },
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _openVerification(RegisterScreen(authService: widget.authService)),
                        child: Text.rich(
                          TextSpan(
                            text: "Don't have an account? ",
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                            children: [
                              TextSpan(
                                text: 'Register',
                                style: TextStyle(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
