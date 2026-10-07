import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

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

/// A form-level error that slides open beneath the fields.
class AuthError extends StatelessWidget {
  const AuthError({super.key, required this.message});

  final String? message;

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
              child: InfoBanner(tone: BannerTone.danger, message: Text(message!)),
            ),
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
