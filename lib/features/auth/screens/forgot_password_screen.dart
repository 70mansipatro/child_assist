import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/widgets/widgets.dart';
import '../services/auth_service.dart';
import '../widgets/auth_widgets.dart';
import 'verify_reset_code_screen.dart';

/// First step of "Forgot password": asks for the account's email and has a reset code sent.
/// Pops with the email once the password has been reset, so Login can prefill it; pops with null
/// for "Back to Login".
///
/// The server's answer is the same whether or not the email has an account, so this screen always
/// moves on to the code step with the same generic message.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, required this.authService, this.initialEmail = ''});

  final AuthService authService;
  final String initialEmail;

  static const sentNotice = 'If an account exists for this email, we sent a password reset code.';

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _emailController = TextEditingController(text: widget.initialEmail);
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || !_formKey.currentState!.validate()) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final email = _emailController.text.trim().toLowerCase();
    try {
      await widget.authService.forgotPassword(email: email);
      if (!mounted) return;
      setState(() => _sending = false);
      // "Change Email" comes back here with the field as it was; a finished reset goes to Login.
      final resetFor = await Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => VerifyResetCodeScreen(
          authService: widget.authService,
          email: email,
          notice: ForgotPasswordScreen.sentNotice,
        ),
      ));
      if (resetFor != null && mounted) Navigator.of(context).pop(resetFor);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.fieldErrors['email'] ?? e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: Colors.white),
      body: AuthBackdrop(
        headerHeight: 250,
        top: kToolbarHeight,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AuthBrand(
                showLogo: false,
                title: 'Forgot Password?',
                subtitle: "No worries, we'll help you get back in.",
              ),
              const SizedBox(height: 20),
              FadeSlideIn(
                index: 1,
                child: AppCard(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: PopIn(child: IconBadge(icon: Icons.lock_reset_rounded, size: 56))),
                      const SizedBox(height: 16),
                      Text(
                        'Enter the email address associated with your Child Assist account.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: _emailController,
                        enabled: !_sending,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.send,
                        onFieldSubmitted: (_) => _send(),
                        validator: AuthValidators.email,
                      ),
                      AuthError(message: _error),
                      const SizedBox(height: 18),
                      GradientButton(
                        onPressed: _sending ? null : _send,
                        label: _sending ? const ButtonSpinner() : const Text('Send Code'),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: _sending ? null : () => Navigator.of(context).pop(),
                        child: Text('Back to Login', style: TextStyle(color: muted, fontWeight: FontWeight.w600)),
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
