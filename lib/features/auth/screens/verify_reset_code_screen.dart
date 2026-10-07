import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/widgets/widgets.dart';
import '../services/auth_service.dart';
import '../widgets/auth_widgets.dart';
import 'reset_password_screen.dart';
import 'verify_email_screen.dart' show OtpCodeField;

/// Second step of "Forgot password": the 6-digit code from the reset email. A correct code returns
/// a short-lived reset token (never a session), which opens Create New Password. Pops with the
/// email once the password is reset; pops with null for "Change Email" or back.
///
/// The code and token live only in this screen's state; neither is logged or stored. The countdowns
/// are only a guide: the server decides whether a code is valid and whether a resend is allowed.
class VerifyResetCodeScreen extends StatefulWidget {
  const VerifyResetCodeScreen({super.key, required this.authService, required this.email, this.notice});

  final AuthService authService;
  final String email;

  /// Shown above the code, e.g. the generic "if an account exists" message.
  final String? notice;

  static const codeLength = 6;
  static const codeLifetime = Duration(minutes: 10);
  static const resendCooldown = Duration(seconds: 60);

  @override
  State<VerifyResetCodeScreen> createState() => _VerifyResetCodeScreenState();
}

class _VerifyResetCodeScreenState extends State<VerifyResetCodeScreen> {
  final _codeController = TextEditingController();
  final _codeFocus = FocusNode();
  Timer? _ticker;

  // Counted down once a second. A code was requested just before this screen opened.
  int _expiresIn = VerifyResetCodeScreen.codeLifetime.inSeconds;
  int _resendIn = VerifyResetCodeScreen.resendCooldown.inSeconds;

  bool _verifying = false;
  bool _resending = false;
  String? _message;
  BannerTone _tone = BannerTone.danger;

  /// Set once the code is verified, so going back from Create New Password does not cost a code.
  String? _resetToken;

  bool get _busy => _verifying || _resending;
  bool get _expired => _expiresIn <= 0 && _resetToken == null;
  bool get _codeComplete => _codeController.text.length == VerifyResetCodeScreen.codeLength;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _codeController.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  void _tick() {
    if (_expiresIn <= 0 && _resendIn <= 0) return;
    setState(() {
      if (_expiresIn > 0) _expiresIn--;
      if (_resendIn > 0) _resendIn--;
    });
  }

  void _show(String? message, [BannerTone tone = BannerTone.danger]) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _tone = tone;
    });
  }

  Future<void> _verify() async {
    if (_busy || !_codeComplete || _expired || _resetToken != null) return;
    setState(() {
      _verifying = true;
      _message = null;
    });
    try {
      final token = await widget.authService.verifyResetCode(email: widget.email, code: _codeController.text);
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _resetToken = token;
      });
      await _createNewPassword();
    } on ApiException catch (e) {
      _codeController.clear();
      _show(e.fieldErrors['code'] ?? e.message);
      _codeFocus.requestFocus();
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _createNewPassword() async {
    final token = _resetToken;
    if (token == null) return;
    final result = await Navigator.of(context).push<ResetPasswordResult>(MaterialPageRoute(
      builder: (_) => ResetPasswordScreen(authService: widget.authService, email: widget.email, resetToken: token),
    ));
    if (!mounted) return;
    switch (result) {
      case ResetPasswordResult.done:
        Navigator.of(context).pop(widget.email);
      case ResetPasswordResult.restart:
        // The token expired or was replaced: a new code is needed.
        _codeController.clear();
        setState(() => _resetToken = null);
        _show('Your reset session has expired. Request a new code to continue.');
      case null:
        // Back from Create New Password: the token is kept, so "Create New Password" reopens it.
        break;
    }
  }

  Future<void> _resend() async {
    if (_busy || _resendIn > 0) return;
    setState(() {
      _resending = true;
      _message = null;
    });
    try {
      final message = await widget.authService.resendResetCode(email: widget.email);
      if (!mounted) return;
      _codeController.clear();
      setState(() {
        _resetToken = null;
        _expiresIn = VerifyResetCodeScreen.codeLifetime.inSeconds;
        _resendIn = VerifyResetCodeScreen.resendCooldown.inSeconds;
      });
      _show(message, BannerTone.success);
    } on ApiException catch (e) {
      _show(e.message);
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  static String _mmss(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final verified = _resetToken != null;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: Colors.white),
      body: AuthBackdrop(
        headerHeight: 250,
        top: kToolbarHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthBrand(
              showLogo: false,
              title: 'Verify Reset Code',
              subtitle: "Let's make sure it's really you.",
            ),
            const SizedBox(height: 20),
            FadeSlideIn(
              index: 1,
              child: AppCard(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: PopIn(child: IconBadge(icon: Icons.pin_outlined, size: 56))),
                    const SizedBox(height: 16),
                    Text(
                      'We sent a 6-digit code to your email.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.email,
                      key: const ValueKey('reset-email-address'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (widget.notice != null) ...[
                      const SizedBox(height: 14),
                      InfoBanner(tone: BannerTone.info, message: Text(widget.notice!)),
                    ],
                    const SizedBox(height: 22),
                    OtpCodeField(
                      controller: _codeController,
                      focusNode: _codeFocus,
                      enabled: !_busy && !_expired && !verified,
                      hasError: _message != null && _tone == BannerTone.danger,
                      onChanged: (_) {
                        if (_message != null && _tone == BannerTone.danger) _show(null);
                        setState(() {});
                      },
                      onCompleted: _verify,
                    ),
                    const SizedBox(height: 14),
                    if (!verified)
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: _expired
                            ? Text(
                                'This code has expired. Request a new code.',
                                key: const ValueKey('expired'),
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppColors.danger,
                                  fontWeight: FontWeight.w600,
                                ),
                              )
                            : Row(
                                key: const ValueKey('expires'),
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.timer_outlined, size: 16, color: muted),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Code expires in ${_mmss(_expiresIn)}',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: muted,
                                      fontFeatures: const [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    AuthError(message: _message, tone: _tone),
                    const SizedBox(height: 18),
                    if (verified)
                      GradientButton(
                        onPressed: _busy ? null : _createNewPassword,
                        label: const Text('Create New Password'),
                      )
                    else
                      GradientButton(
                        onPressed: _busy || _expired || !_codeComplete ? null : _verify,
                        label: _verifying ? const ButtonSpinner() : const Text('Verify Code'),
                      ),
                    const SizedBox(height: 18),
                    Text(
                      "Didn't receive the code? Check your spam folder.",
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    TextButton(
                      key: const ValueKey('resend-reset-code'),
                      onPressed: _busy || _resendIn > 0 ? null : _resend,
                      child: _resending
                          ? SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
                            )
                          : Text(
                              _resendIn > 0 ? 'Resend code in ${_mmss(_resendIn)}' : 'Resend Code',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      child: Text('Change Email', style: TextStyle(color: muted, fontWeight: FontWeight.w500)),
                    ),
                    const SizedBox(height: 6),
                    // Shown to everyone: whether this email is a Google account is never revealed here.
                    Row(
                      key: const ValueKey('google-account-hint'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded, size: 16, color: muted),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Signed up with Google? Your account has no password to reset. '
                            'Go back and tap Continue with Google instead.',
                            style: theme.textTheme.bodySmall?.copyWith(color: muted),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
