import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/widgets/widgets.dart';
import '../services/auth_service.dart';
import '../widgets/auth_widgets.dart';

/// How Create New Password ended. Back navigation pops with null.
enum ResetPasswordResult {
  /// The password was changed. The user now logs in with it.
  done,

  /// The reset token expired or was replaced: the user needs a new code.
  restart,
}

/// Last step of "Forgot password": sets the new password with the reset token. Uses the same rules
/// as Register. Never signs in; pops with [ResetPasswordResult.done] so Login can take over.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({
    super.key,
    required this.authService,
    required this.email,
    required this.resetToken,
  });

  final AuthService authService;
  final String email;
  final String resetToken;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _submitting = false;
  bool _obscure = true;
  bool _obscureConfirm = true;
  bool _tokenExpired = false;
  String? _error;
  Map<String, String> _fieldErrors = const {};

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _fieldErrors = const {});
    if (_submitting || !_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.authService.resetPassword(
        resetToken: widget.resetToken,
        newPassword: _passwordController.text,
        confirmPassword: _confirmController.text,
      );
      if (mounted) Navigator.of(context).pop(ResetPasswordResult.done);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _tokenExpired = e.code == 'INVALID_RESET_TOKEN';
        _error = e.message;
        _fieldErrors = e.fieldErrors;
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
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
                title: 'Create New Password',
                subtitle: 'Choose a password you have not used here before.',
              ),
              const SizedBox(height: 20),
              FadeSlideIn(
                index: 1,
                child: AppCard(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: PopIn(child: IconBadge(icon: Icons.password_rounded, size: 56))),
                      const SizedBox(height: 16),
                      Text(
                        'New password for',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.email,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: _passwordController,
                        enabled: !_submitting && !_tokenExpired,
                        decoration: InputDecoration(
                          labelText: 'New Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: PasswordVisibilityToggle(
                            obscured: _obscure,
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                          helperText: 'At least ${AuthValidators.minPasswordLength} characters',
                          errorText: _fieldErrors['newPassword'],
                        ),
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.newPassword],
                        textInputAction: TextInputAction.next,
                        validator: AuthValidators.newPassword,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _confirmController,
                        enabled: !_submitting && !_tokenExpired,
                        decoration: InputDecoration(
                          labelText: 'Confirm Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: PasswordVisibilityToggle(
                            obscured: _obscureConfirm,
                            onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                          ),
                          errorText: _fieldErrors['confirmPassword'],
                        ),
                        obscureText: _obscureConfirm,
                        autofillHints: const [AutofillHints.newPassword],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'Please confirm your new password';
                          if (v != _passwordController.text) return 'Passwords do not match';
                          return null;
                        },
                      ),
                      AuthError(message: _fieldErrors.isEmpty ? _error : null),
                      const SizedBox(height: 18),
                      if (_tokenExpired)
                        GradientButton(
                          onPressed: () => Navigator.of(context).pop(ResetPasswordResult.restart),
                          label: const Text('Request a New Code'),
                        )
                      else
                        GradientButton(
                          onPressed: _submitting ? null : _submit,
                          label: _submitting ? const ButtonSpinner() : const Text('Reset Password'),
                        ),
                      const SizedBox(height: 12),
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
