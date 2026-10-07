import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'motion.dart';

/// The primary call to action: a [FilledButton] painted with a brand gradient and a soft glow.
/// It is still a real FilledButton underneath, so semantics, focus and ripples behave natively.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.gradient = AppGradients.brand,
    this.height = 56,
  });

  final VoidCallback? onPressed;
  final Widget label;
  final Widget? icon;
  final Gradient gradient;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final glowColor = gradient.colors.last;
    final radius = BorderRadius.circular(AppSpacing.radius);
    final style = FilledButton.styleFrom(
      backgroundColor: Colors.transparent,
      disabledBackgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white.withValues(alpha: 0.9),
      shadowColor: Colors.transparent,
      minimumSize: Size.fromHeight(height),
      shape: RoundedRectangleBorder(borderRadius: radius),
      textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 16, fontWeight: FontWeight.w600),
    );
    final button = icon == null
        ? FilledButton(onPressed: onPressed, style: style, child: label)
        : FilledButton.icon(onPressed: onPressed, style: style, icon: icon, label: label);

    return PressableScale(
      enabled: enabled,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: enabled ? 1 : 0.6,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: radius,
            boxShadow: enabled ? AppTheme.glow(glowColor, strength: 0.9) : const [],
          ),
          child: button,
        ),
      ),
    );
  }
}

/// A small white spinner sized to sit inside a button.
class ButtonSpinner extends StatelessWidget {
  const ButtonSpinner({super.key, this.color = Colors.white, this.size = 20});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CircularProgressIndicator(strokeWidth: 2.4, color: color, strokeCap: StrokeCap.round),
    );
  }
}

/// The app's standard surface: rounded, softly shadowed in light mode, hairline-bordered in
/// dark mode. Give it [onTap] to make it a pressable, rippling tile.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.onTap,
    this.color,
    this.gradient,
    this.radius = AppSpacing.radiusLg,
    this.borderColor,
    this.shadow = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final Gradient? gradient;
  final double radius;
  final Color? borderColor;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);
    final border = borderColor ?? (isDark && gradient == null ? theme.colorScheme.outlineVariant : null);

    Widget content = Padding(padding: padding, child: child);
    if (onTap != null) {
      content = InkWell(onTap: onTap, borderRadius: borderRadius, child: content);
    }
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: gradient == null ? (color ?? theme.colorScheme.surface) : null,
        gradient: gradient,
        borderRadius: borderRadius,
        border: border == null ? null : Border.all(color: border),
        boxShadow: !shadow
            ? null
            : gradient != null
            ? AppTheme.glow(gradient!.colors.last, strength: 0.7)
            : AppTheme.softShadow(context),
      ),
      // Clip at the rounded edge (not inner layout bounds) so child glows fade out cleanly.
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Material(type: MaterialType.transparency, child: content),
      ),
    );
    return onTap == null ? card : PressableScale(child: card);
  }
}

/// A rounded square holding an icon on a gradient, used to give every feature a recognisable
/// colour mark.
class IconBadge extends StatelessWidget {
  const IconBadge({
    super.key,
    required this.icon,
    this.gradient = AppGradients.brand,
    this.size = 48,
    this.iconSize,
    this.glow = true,
  });

  final IconData icon;
  final Gradient gradient;
  final double size;
  final double? iconSize;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(size * 0.32),
          boxShadow: glow ? AppTheme.glow(gradient.colors.last, strength: 0.6) : null,
        ),
        child: Icon(icon, color: Colors.white, size: iconSize ?? size * 0.5),
      ),
    );
  }
}

/// The Child Assist mark: a shield with a heart, on the brand gradient.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 64, this.onDark = false});

  final double size;

  /// When shown on a gradient header, the logo becomes a frosted white tile.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: onDark ? null : AppGradients.brand,
          color: onDark ? Colors.white.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(size * 0.3),
          border: onDark ? Border.all(color: Colors.white.withValues(alpha: 0.35)) : null,
          boxShadow: onDark ? null : AppTheme.glow(AppColors.primary),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(Icons.shield_rounded, color: Colors.white, size: size * 0.6),
            Padding(
              padding: EdgeInsets.only(bottom: size * 0.04),
              child: Icon(
                Icons.favorite_rounded,
                color: onDark ? AppColors.primaryDeep : AppColors.primary,
                size: size * 0.26,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A gradient panel with soft decorative circles, used as the top of Home, Login and Profile.
class HeroHeader extends StatelessWidget {
  const HeroHeader({
    super.key,
    required this.child,
    this.gradient = AppGradients.hero,
    this.padding = const EdgeInsets.fromLTRB(24, 16, 24, 32),
    this.bottomRadius = 0,
  });

  final Widget child;
  final Gradient gradient;
  final EdgeInsetsGeometry padding;
  final double bottomRadius;

  @override
  Widget build(BuildContext context) {
    // White status-bar icons while the header sits under the status bar.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: _buildPanel(),
    );
  }

  Widget _buildPanel() {
    return ClipRRect(
      borderRadius: BorderRadius.vertical(bottom: Radius.circular(bottomRadius)),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: gradient),
        child: Stack(
          children: [
            const Positioned(top: -60, right: -40, child: _Bubble(size: 200, alpha: 0.10)),
            const Positioned(bottom: -70, left: -50, child: _Bubble(size: 180, alpha: 0.08)),
            const Positioned(top: 40, right: 90, child: _Bubble(size: 36, alpha: 0.14)),
            SizedBox(
              width: double.infinity,
              child: Padding(padding: padding, child: child),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.size, required this.alpha});

  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: alpha),
        ),
      ),
    );
  }
}

/// The fill behind every screen's [AppBar] (pass as `flexibleSpace`): the same gradient and
/// soft circles as the Dashboard and Profile headers, sized for a toolbar.
class AppBarGradient extends StatelessWidget {
  const AppBarGradient({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(gradient: AppGradients.hero),
      child: ClipRect(
        child: Stack(
          children: [
            Positioned(top: -70, right: -40, child: _Bubble(size: 170, alpha: 0.10)),
            Positioned(bottom: -60, left: -40, child: _Bubble(size: 120, alpha: 0.08)),
            SizedBox.expand(),
          ],
        ),
      ),
    );
  }
}

/// A section heading with an optional trailing action.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (subtitle != null) Text(subtitle!, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

enum BannerTone { info, success, warning, danger }

/// An inline callout: tinted background, leading icon, message and optional actions.
class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.message,
    this.icon,
    this.tone = BannerTone.info,
    this.title,
    this.actions = const [],
  });

  final Widget message;
  final String? title;
  final IconData? icon;
  final BannerTone tone;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = toneColor(context, tone);
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.09),
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(11)),
            child: Icon(icon ?? _defaultIcon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null) ...[Text(title!, style: theme.textTheme.titleSmall), const SizedBox(height: 2)],
                DefaultTextStyle.merge(
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
                  child: message,
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: actions),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData get _defaultIcon => switch (tone) {
    BannerTone.info => Icons.info_outline_rounded,
    BannerTone.success => Icons.check_circle_outline_rounded,
    BannerTone.warning => Icons.warning_amber_rounded,
    BannerTone.danger => Icons.error_outline_rounded,
  };

  static Color toneColor(BuildContext context, BannerTone tone) => switch (tone) {
    BannerTone.info => Theme.of(context).colorScheme.primary,
    BannerTone.success => AppColors.success,
    BannerTone.warning => AppColors.warning,
    BannerTone.danger => AppColors.danger,
  };
}

/// A full-area empty / error / permission state: an illustrated icon, a title, a short
/// explanation and an optional action. The icon pops in and the text fades up.
class StateMessage extends StatelessWidget {
  const StateMessage({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.secondaryAction,
    this.gradient = AppGradients.brand,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  final Widget? secondaryAction;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = gradient.colors.first;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PopIn(
                child: ExcludeSemantics(
                  child: Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withValues(alpha: 0.10)),
                    alignment: Alignment.center,
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: gradient,
                        boxShadow: AppTheme.glow(gradient.colors.last, strength: 0.8),
                      ),
                      child: Icon(icon, size: 36, color: Colors.white),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FadeSlideIn(
                index: 1,
                child: Column(
                  children: [
                    Text(title, style: theme.textTheme.titleLarge?.copyWith(fontSize: 19), textAlign: TextAlign.center),
                    if (body != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        body!,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 24),
                FadeSlideIn(
                  index: 2,
                  child: ConstrainedBox(constraints: const BoxConstraints(minWidth: 200), child: action!),
                ),
              ],
              if (secondaryAction != null) ...[const SizedBox(height: 8), secondaryAction!],
            ],
          ),
        ),
      ),
    );
  }
}

/// One row of a settings-style list: a gradient icon, a title, an optional subtitle and a
/// trailing chevron (or any [trailing] widget). Group several inside an [AppCard].
class MenuTile extends StatelessWidget {
  const MenuTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.gradient = AppGradients.brand,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Gradient gradient;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: IconBadge(icon: icon, gradient: gradient, size: 40, glow: false),
      title: Text(title, style: theme.textTheme.titleSmall),
      subtitle: subtitle == null ? null : Text(subtitle!, style: theme.textTheme.bodySmall),
      trailing: trailing ??
          (onTap == null ? null : Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// The full-width "Logout" button. Shows a spinner while signing out.
class LogoutButton extends StatelessWidget {
  const LogoutButton({super.key, required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: busy ? null : onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.danger,
        side: BorderSide(color: AppColors.danger.withValues(alpha: 0.4)),
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.radius)),
      ),
      icon: busy ? const ButtonSpinner(size: 18, color: AppColors.danger) : const Icon(Icons.logout_rounded),
      label: const Text('Logout'),
    );
  }
}

/// A coloured dot used to show a status at a glance.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 6)],
      ),
    );
  }
}

/// The branded full-screen loader shown while the app decides where to go.
class SplashView extends StatelessWidget {
  const SplashView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppGradients.hero),
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopIn(child: AppLogo(size: 84, onDark: true)),
            SizedBox(height: 28),
            ButtonSpinner(size: 26),
          ],
        ),
      ),
    );
  }
}
