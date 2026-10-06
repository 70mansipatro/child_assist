import 'package:flutter/material.dart';

/// Fades and slides [child] into place once, when it is first built. [index] staggers a
/// group of siblings so a list or grid cascades in. Respects the OS "reduce motion" setting.
///
/// Uses a single tween (no timers), so it never leaves work pending after it finishes.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.index = 0,
    this.offset = const Offset(0, 24),
    this.duration = const Duration(milliseconds: 520),
    this.stagger = const Duration(milliseconds: 70),
  });

  final Widget child;
  final int index;
  final Offset offset;
  final Duration duration;
  final Duration stagger;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    final delay = stagger * index;
    final total = duration + delay;
    final start = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: offset * (1 - t), child: child),
      ),
    );
  }
}

/// Grows [child] from a smaller size with a gentle overshoot, once. Used for hero icons.
class PopIn extends StatelessWidget {
  const PopIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 650),
    this.from = 0.6,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;
  final double from;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    final total = duration + delay;
    final start = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1),
      child: child,
      builder: (context, t, child) {
        final scale = from + (1 - from) * Curves.easeOutBack.transform(t);
        return Opacity(
          opacity: Curves.easeOut.transform(t),
          child: Transform.scale(scale: scale, child: child),
        );
      },
    );
  }
}

/// Shrinks slightly while pressed, for tactile feedback on cards and tiles. It only listens
/// to the pointer, so the child's own InkWell/button still receives the tap.
class PressableScale extends StatefulWidget {
  const PressableScale({super.key, required this.child, this.enabled = true, this.scale = 0.97});

  final Widget child;
  final bool enabled;
  final double scale;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  void _set(bool value) {
    if (_pressed != value && mounted) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// A pulsing halo behind [child] (e.g. a location pin while the device is locating).
/// Repeats until removed from the tree, so only show it while work is in progress.
class PulseHalo extends StatefulWidget {
  const PulseHalo({super.key, required this.child, required this.color, this.size = 120});

  final Widget child;
  final Color color;
  final double size;

  @override
  State<PulseHalo> createState() => _PulseHaloState();
}

class _PulseHaloState extends State<PulseHalo> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) => Stack(
          alignment: Alignment.center,
          children: [
            for (final phase in const [0.0, 0.5])
              _ring(((_controller.value + phase) % 1.0)),
            child!,
          ],
        ),
      ),
    );
  }

  Widget _ring(double t) {
    final eased = Curves.easeOut.transform(t);
    return Container(
      width: widget.size * (0.35 + 0.65 * eased),
      height: widget.size * (0.35 + 0.65 * eased),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color.withValues(alpha: 0.28 * (1 - t)),
      ),
    );
  }
}
