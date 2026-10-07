import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/widgets/widgets.dart';
import '../services/auth_service.dart';
import '../services/google_auth_service.dart';

/// The gradient wash behind the sign-in screens, with the form centred and scrollable.
class AuthBackdrop extends StatelessWidget {
  const AuthBackdrop({super.key, required this.child, this.headerHeight = 280, this.top = 24});

  final Widget child;
  final double headerHeight;

  /// Space above the content, e.g. to clear a transparent app bar.
  final double top;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: headerHeight + MediaQuery.paddingOf(context).top,
          child: const HeroHeader(child: SizedBox.expand()),
        ),
        // Anchored to the top so the brand always sits on the gradient and the form card
        // overlaps the header's lower edge, whatever the screen height.
        SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, top, 20, 20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Logo, app name and a one-line welcome, shown on the gradient above the form.
class AuthBrand extends StatelessWidget {
  const AuthBrand({super.key, required this.subtitle, this.title = 'Child Assist', this.showLogo = true});

  final String title;
  final String subtitle;
  final bool showLogo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        if (showLogo) ...[
          const PopIn(child: AppLogo(size: 58, onDark: true)),
          const SizedBox(height: 12),
        ],
        FadeSlideIn(
          child: Column(
            children: [
              Text(title, style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A form-level message (an error by default) that slides open beneath the fields.
class AuthError extends StatelessWidget {
  const AuthError({super.key, required this.message, this.tone = BannerTone.danger});

  final String? message;
  final BannerTone tone;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: message == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 14),
              child: InfoBanner(tone: tone, message: Text(message!)),
            ),
    );
  }
}

/// "──── OR ────" between the password form and other sign-in options.
class AuthDivider extends StatelessWidget {
  const AuthDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'OR',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}

/// A "Continue with Google" button styled per Google's sign-in branding guidelines: the official
/// "G" mark (unaltered asset), Roboto Medium label, and Google's light/dark fill and stroke colours.
/// Only the corner radius and height follow Child Assist, which the guidelines allow.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({super.key, required this.onPressed, this.busy = false});

  final VoidCallback? onPressed;
  final bool busy;

  static const label = 'Continue with Google';

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark ? const Color(0xFF131314) : Colors.white;
    final stroke = dark ? const Color(0xFF8E918F) : const Color(0xFF747775);
    final text = dark ? const Color(0xFFE3E3E3) : const Color(0xFF1F1F1F);
    final enabled = onPressed != null && !busy;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        // Google's disabled style: 38% content over a faded container.
        opacity: enabled || busy ? 1 : 0.6,
        child: OutlinedButton(
          onPressed: busy ? null : onPressed,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: fill,
            disabledBackgroundColor: fill,
            foregroundColor: text,
            disabledForegroundColor: text,
            side: BorderSide(color: stroke),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.radius)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              busy
                  ? SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: stroke),
                    )
                  : Image.asset(
                      dark ? 'assets/google/g_logo_dark.png' : 'assets/google/g_logo_light.png',
                      width: 20,
                      height: 20,
                      filterQuality: FilterQuality.medium,
                    ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 14,
                    height: 20 / 14,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.25,
                    color: text,
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

/// The "OR" divider plus "Continue with Google", with its own progress and messages. Signs in to,
/// or creates, the account for the chosen Google account; on success AuthService notifies and the
/// app switches to the signed-in screens. Renders nothing where Google sign-in is unavailable.
class ContinueWithGoogle extends StatefulWidget {
  const ContinueWithGoogle({super.key, required this.authService, this.enabled = true, this.onBusyChanged});

  final AuthService authService;

  /// False while the password form is submitting.
  final bool enabled;

  /// Lets the screen disable its own form while Google sign-in is in progress.
  final ValueChanged<bool>? onBusyChanged;

  @override
  State<ContinueWithGoogle> createState() => _ContinueWithGoogleState();
}

class _ContinueWithGoogleState extends State<ContinueWithGoogle> {
  bool _busy = false;
  String? _message;
  BannerTone _tone = BannerTone.danger;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    widget.onBusyChanged?.call(true);
    try {
      await widget.authService.loginWithGoogle();
    } on GoogleAuthException catch (e) {
      _show(e.message, e.cancelled ? BannerTone.info : BannerTone.danger);
    } on ApiException catch (e) {
      _show(e.message, e.code == 'ACCOUNT_EXISTS_WITH_PASSWORD' ? BannerTone.warning : BannerTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onBusyChanged?.call(false);
    }
  }

  void _show(String message, BannerTone tone) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _tone = tone;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.authService.googleSignInAvailable) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        const AuthDivider(),
        const SizedBox(height: 14),
        GoogleSignInButton(busy: _busy, onPressed: widget.enabled ? _signIn : null),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _message == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: InfoBanner(tone: _tone, message: Text(_message!)),
                ),
        ),
      ],
    );
  }
}

/// The eye button at the end of a password field.
class PasswordVisibilityToggle extends StatelessWidget {
  const PasswordVisibilityToggle({super.key, required this.obscured, required this.onPressed});

  final bool obscured;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: obscured ? 'Show password' : 'Hide password',
      onPressed: onPressed,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
        child: Icon(
          obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          key: ValueKey(obscured),
        ),
      ),
    );
  }
}

/// Form rules shared by Register and Reset Password. They mirror the server's, which still checks.
abstract final class AuthValidators {
  static const minPasswordLength = 8;

  /// bcrypt only uses the first 72 bytes of a password, so the server refuses anything longer.
  static const maxPasswordBytes = 72;

  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static String? email(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Please enter your email';
    if (!_email.hasMatch(value)) return 'Please enter a valid email';
    return null;
  }

  static String? newPassword(String? v) {
    if (v == null || v.length < minPasswordLength) {
      return 'Password must be at least $minPasswordLength characters';
    }
    if (utf8.encode(v).length > maxPasswordBytes) return 'Password is too long';
    return null;
  }
}
