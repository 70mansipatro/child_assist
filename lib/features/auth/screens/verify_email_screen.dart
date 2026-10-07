import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api/api_client.dart';
import '../../../core/widgets/widgets.dart';
import '../services/auth_service.dart';
import '../widgets/auth_widgets.dart';

/// Asks for the 6-digit code emailed to a new password account. Opened after Register, or from
/// Login when the account is not verified yet. Pops with the verified email on success, so the
/// screen underneath (Login) can prefill it; pops with null for "Change email" or back.
///
/// The code is never logged or kept beyond the text field. The countdowns are only a guide: the
/// server decides whether a code is valid and whether a resend is allowed.
class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key, required this.authService, required this.email, this.notice});

  final AuthService authService;
  final String email;

  /// Shown above the code, e.g. why Login sent the user here.
  final String? notice;

  static const codeLength = 6;
  static const codeLifetime = Duration(minutes: 10);
  static const resendCooldown = Duration(seconds: 60);

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  final _codeController = TextEditingController();
  final _codeFocus = FocusNode();
  Timer? _ticker;

  // Counted down once a second. A code was sent just before this screen opened.
  int _expiresIn = VerifyEmailScreen.codeLifetime.inSeconds;
  int _resendIn = VerifyEmailScreen.resendCooldown.inSeconds;

  bool _verifying = false;
  bool _resending = false;
  String? _message;
  BannerTone _tone = BannerTone.danger;

  bool get _busy => _verifying || _resending;
  bool get _expired => _expiresIn <= 0;
  bool get _codeComplete => _codeController.text.length == VerifyEmailScreen.codeLength;

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
    if (_busy || !_codeComplete || _expired) return;
    setState(() {
      _verifying = true;
      _message = null;
    });
    try {
      await widget.authService.verifyEmail(email: widget.email, code: _codeController.text);
      // Back to Login, which shows "Email verified successfully" with the email filled in.
      if (mounted) Navigator.of(context).pop(widget.email);
    } on ApiException catch (e) {
      _codeController.clear();
      _show(e.fieldErrors['code'] ?? e.message);
      _codeFocus.requestFocus();
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _resend() async {
    if (_busy || _resendIn > 0) return;
    setState(() {
      _resending = true;
      _message = null;
    });
    try {
      final message = await widget.authService.resendVerification(email: widget.email);
      if (!mounted) return;
      _codeController.clear();
      setState(() {
        _expiresIn = VerifyEmailScreen.codeLifetime.inSeconds;
        _resendIn = VerifyEmailScreen.resendCooldown.inSeconds;
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
              title: 'Verify Email',
              subtitle: 'One last step to secure your account.',
            ),
            const SizedBox(height: 20),
            FadeSlideIn(
              index: 1,
              child: AppCard(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: PopIn(child: IconBadge(icon: Icons.mark_email_read_outlined, size: 56))),
                    const SizedBox(height: 16),
                    Text(
                      'We sent a 6-digit code to',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.email,
                      key: const ValueKey('verify-email-address'),
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
                      enabled: !_busy && !_expired,
                      hasError: _message != null && _tone == BannerTone.danger,
                      onChanged: (_) {
                        if (_message != null && _tone == BannerTone.danger) _show(null);
                        setState(() {});
                      },
                      onCompleted: _verify,
                    ),
                    const SizedBox(height: 14),
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
                    GradientButton(
                      onPressed: _busy || _expired || !_codeComplete ? null : _verify,
                      label: _verifying ? const ButtonSpinner() : const Text('Verify Email'),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      "Didn't receive it? Check your spam folder.",
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    TextButton(
                      key: const ValueKey('resend-code'),
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
                      child: Text(
                        'Change email',
                        style: TextStyle(color: muted, fontWeight: FontWeight.w500),
                      ),
                    ),
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

/// Six digit boxes over a single invisible text field, so typing, deleting, pasting and the
/// keyboard's one-time-code autofill all work as in a normal field.
class OtpCodeField extends StatelessWidget {
  const OtpCodeField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.enabled = true,
    this.hasError = false,
    this.onChanged,
    this.onCompleted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool hasError;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onCompleted;

  static const length = VerifyEmailScreen.codeLength;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = theme.inputDecorationTheme.fillColor ?? theme.colorScheme.surfaceContainerHighest;
    return Semantics(
      label: '6-digit verification code',
      child: SizedBox(
        height: 58,
        child: Stack(
          children: [
            ListenableBuilder(
              listenable: Listenable.merge([controller, focusNode]),
              builder: (context, _) {
                final text = controller.text;
                return Row(
                  children: [
                    for (var i = 0; i < length; i++) ...[
                      if (i > 0) SizedBox(width: i == length ~/ 2 ? 14 : 8),
                      Expanded(
                        child: _DigitBox(
                          digit: i < text.length ? text[i] : null,
                          active: enabled && focusNode.hasFocus && i == text.length.clamp(0, length - 1),
                          error: hasError,
                          fill: fill,
                          enabled: enabled,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
            Positioned.fill(
              child: TextField(
                key: const ValueKey('otp-input'),
                controller: controller,
                focusNode: focusNode,
                enabled: enabled,
                autofocus: true,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(length),
                ],
                showCursor: false,
                enableInteractiveSelection: false,
                style: const TextStyle(color: Colors.transparent, fontSize: 1),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,
                  counterText: '',
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: (value) {
                  onChanged?.call(value);
                  if (value.length == length) onCompleted?.call();
                },
                onSubmitted: (_) => onCompleted?.call(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DigitBox extends StatelessWidget {
  const _DigitBox({
    required this.digit,
    required this.active,
    required this.error,
    required this.fill,
    required this.enabled,
  });

  final String? digit;
  final bool active;
  final bool error;
  final Color fill;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final borderColor = error
        ? AppColors.danger
        : active
            ? primary
            : digit != null
                ? primary.withValues(alpha: 0.45)
                : theme.colorScheme.outlineVariant;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: enabled ? fill : fill.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: borderColor, width: active || error ? 2 : 1.2),
        boxShadow: active ? AppTheme.glow(primary, strength: 0.35) : null,
      ),
      child: Text(
        digit ?? '',
        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}
