import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/widgets/widgets.dart';
import '../services/auth_service.dart';
import '../widgets/auth_widgets.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.authService});

  final AuthService authService;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  static const _minPasswordLength = 8;

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  bool _obscure = true;
  String? _error;
  Map<String, String> _fieldErrors = const {};

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _fieldErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.authService.register(
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      // Signed in: the root now shows Home, so drop this pushed route.
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _fieldErrors = e.fieldErrors;
        });
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                title: 'Create account',
                subtitle: 'Join Child Assist in less than a minute.',
              ),
              const SizedBox(height: 20),
              FadeSlideIn(
                index: 1,
                child: AppCard(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _nameController,
                        decoration: InputDecoration(
                          labelText: 'Name',
                          prefixIcon: const Icon(Icons.person_outline_rounded),
                          errorText: _fieldErrors['name'],
                        ),
                        textCapitalization: TextCapitalization.words,
                        autofillHints: const [AutofillHints.name],
                        textInputAction: TextInputAction.next,
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Please enter your name' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          labelText: 'Email',
                          prefixIcon: const Icon(Icons.alternate_email_rounded),
                          errorText: _fieldErrors['email'],
                        ),
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.next,
                        validator: (v) {
                          final value = v?.trim() ?? '';
                          if (value.isEmpty) return 'Please enter your email';
                          if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) {
                            return 'Please enter a valid email';
                          }
                          return null;
                        },
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
                          helperText: 'At least $_minPasswordLength characters',
                          errorText: _fieldErrors['password'],
                        ),
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.newPassword],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submitting ? null : _submit(),
                        validator: (v) => (v == null || v.length < _minPasswordLength)
                            ? 'Password must be at least $_minPasswordLength characters'
                            : null,
                      ),
                      AuthError(message: _fieldErrors.isEmpty ? _error : null),
                      const SizedBox(height: 18),
                      GradientButton(
                        onPressed: _submitting ? null : _submit,
                        label: _submitting ? const ButtonSpinner() : const Text('Register'),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.verified_user_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Your details stay private to your account.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
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
