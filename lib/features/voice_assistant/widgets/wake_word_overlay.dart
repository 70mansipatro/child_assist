import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/wake_word_ui_state.dart';
import '../services/wake_word_service.dart';
import 'siri_waveform.dart';

/// Dark navy with a hint of indigo and violet, behind every waveform.
const _navy = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xF20A0F2C), Color(0xF2141443), Color(0xF2231A55)],
);

/// Where the waveform sits at the top of the screen: centred on the front camera's cutout when the
/// phone reports one (Android passes cutouts to Flutter as display features), otherwise centred
/// in the status bar. Recomputed from [MediaQueryData], so it follows rotation and screen size.
@immutable
class NotchAnchor {
  const NotchAnchor({required this.center, this.cutout = Size.zero});

  /// The middle of the camera cutout, or of the status bar.
  final Offset center;

  /// The camera cutout's size; [Size.zero] when there is none at the top.
  final Size cutout;

  bool get fromCutout => cutout != Size.zero;

  static NotchAnchor of(MediaQueryData media) {
    final width = media.size.width;
    final top = media.viewPadding.top;
    Rect? best;
    for (final feature in media.displayFeatures) {
      if (feature.type != ui.DisplayFeatureType.cutout) continue;
      final bounds = feature.bounds;
      // Only a camera on the top edge; side cutouts (e.g. in landscape) are left alone.
      if (bounds.isEmpty || bounds.top > top + 1 || bounds.center.dy > media.size.height / 4) continue;
      if (best == null || (bounds.center.dx - width / 2).abs() < (best.center.dx - width / 2).abs()) best = bounds;
    }
    if (best != null) return NotchAnchor(center: best.center, cutout: best.size);
    return NotchAnchor(center: Offset(width / 2, top > 0 ? top / 2 : 18));
  }
}

/// The "Hey Child" waveform at the top of the app, centred on the camera cutout, while a question
/// is in progress or something went wrong. Shown above every screen (place it above the Navigator),
/// it only reflects [WakeWordService]; it never starts or stops anything and lets every touch
/// through to the app below. Nothing is built, and nothing animates, while there is nothing to show.
///
/// Inside the app this widget draws it. While Child Assist is not on screen (Home screen, another
/// app, lock screen) the same state is handed to the phone's own overlay instead
/// ([WakeWordService.showSystemOverlay]), which needs "Display over other apps"; without it nothing
/// is drawn outside the app and the wake word's notification remains.
class WakeWordNotchOverlay extends StatefulWidget {
  const WakeWordNotchOverlay({super.key, required this.wakeWord, this.errorDuration = const Duration(seconds: 4)});

  final WakeWordService wakeWord;
  final Duration errorDuration;

  @override
  State<WakeWordNotchOverlay> createState() => _WakeWordNotchOverlayState();
}

class _WakeWordNotchOverlayState extends State<WakeWordNotchOverlay> {
  late final _ui = WakeWordUiController(widget.wakeWord, errorDuration: widget.errorDuration);
  late final _lifecycle = AppLifecycleListener(onStateChange: (_) => _syncOutside());

  /// What the overlay outside the app shows now, or null when it is hidden.
  String? _outside;

  @override
  void initState() {
    super.initState();
    _ui.addListener(_syncOutside);
    _lifecycle;
  }

  /// Outside the app only while Child Assist is not on screen, and only for a question or an error.
  void _syncOutside() {
    final phase = _ui.phase;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final onScreen = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    final show = !onScreen && phase != null && phase != WakeWordUiPhase.idle;
    final next = show ? '${phase.name}|${_ui.title}|${_ui.detail}' : null;
    if (next == _outside) return;
    _outside = next;
    if (show) {
      widget.wakeWord.showSystemOverlay(phase: phase.name, title: _ui.title, hint: _ui.detail);
    } else {
      widget.wakeWord.hideSystemOverlay();
    }
  }

  @override
  void dispose() {
    _ui.removeListener(_syncOutside);
    if (_outside != null) widget.wakeWord.hideSystemOverlay();
    _lifecycle.dispose();
    _ui.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animate = !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: ListenableBuilder(
          listenable: _ui,
          builder: (context, _) {
            final phase = _ui.phase;
            // Waiting for the phrase is shown where it fits (Chat, Settings), not over every screen.
            final show = phase != null && phase != WakeWordUiPhase.idle;
            return AnimatedSwitcher(
              duration: animate ? const Duration(milliseconds: 280) : Duration.zero,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween(begin: 0.85, end: 1.0).animate(animation),
                  alignment: Alignment.topCenter,
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              child: show
                  ? _Island(
                      key: const ValueKey('wake-island'),
                      phase: phase,
                      message: _ui.message,
                      level: _ui.level,
                      animate: animate,
                    )
                  : const SizedBox.shrink(key: ValueKey('wake-none')),
            );
          },
        ),
      ),
    );
  }
}

/// Starts as a pill around the camera and expands into a card with the status underneath.
class _Island extends StatefulWidget {
  const _Island({super.key, required this.phase, required this.message, required this.level, required this.animate});

  final WakeWordUiPhase phase;
  final String message;
  final ValueListenable<double?> level;
  final bool animate;

  @override
  State<_Island> createState() => _IslandState();
}

class _IslandState extends State<_Island> {
  late bool _expanded = !widget.animate;

  @override
  void initState() {
    super.initState();
    if (!_expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _expanded = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final anchor = NotchAnchor.of(media);
    final screen = media.size.width;
    final rowHeight = (anchor.cutout.height + 14).clamp(38.0, 64.0).toDouble();
    final pillWidth = math.max(anchor.cutout.width + 112, 150.0);
    final cardWidth = math.min(screen - 32, 380.0);
    final width = math.min(_expanded ? cardWidth : pillWidth, screen - 16);
    final left = (anchor.center.dx - width / 2).clamp(8.0, math.max(8.0, screen - 8 - width)).toDouble();
    final top = math.max(4.0, anchor.center.dy - rowHeight / 2);
    final duration = widget.animate ? const Duration(milliseconds: 420) : Duration.zero;
    final radius = _expanded ? 28.0 : rowHeight / 2;

    return Stack(
      children: [
        AnimatedPositioned(
          duration: duration,
          curve: Curves.easeOutCubic,
          top: top,
          left: left,
          width: width,
          child: Semantics(
            liveRegion: true,
            container: true,
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                gradient: _navy,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                boxShadow: const [
                  BoxShadow(color: Color(0x668B5CF6), blurRadius: 30, spreadRadius: -6, offset: Offset(0, 8)),
                ],
              ),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: _grow(
                  duration,
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The camera sits in the middle of this row; the wave flows out on both sides.
                      SizedBox(
                        height: rowHeight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: SiriWaveform(phase: widget.phase, level: widget.level),
                        ),
                      ),
                      if (_expanded) _Caption(phase: widget.phase, message: widget.message),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Grows smoothly to fit the caption; with reduced motion it simply changes size
  /// (AnimatedSize does not support a zero duration).
  Widget _grow(Duration duration, Widget child) => duration == Duration.zero
      ? child
      : AnimatedSize(duration: duration, curve: Curves.easeOutCubic, alignment: Alignment.topCenter, child: child);
}

class _Caption extends StatelessWidget {
  const _Caption({required this.phase, required this.message});

  final WakeWordUiPhase phase;
  final String message;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final error = phase == WakeWordUiPhase.error;
    // Same wording as WakeWordUiController.title / detail, used by the overlay outside the app.
    final title = error ? 'Oops!' : message;
    final body = error ? message : phase.hint;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error) ...[
                const Icon(Icons.error_outline_rounded, color: Color(0xFFFF8FA3), size: 20),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: text.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (body != null) ...[
            const SizedBox(height: 4),
            Text(
              body,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.78)),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Say “Hey Child”" with a calm waveform, while the wake word is really listening for its phrase.
/// Shows nothing otherwise, so it never claims to listen when it does not.
class WakeWordIdleHint extends StatelessWidget {
  const WakeWordIdleHint({super.key, required this.wakeWord, this.padding = EdgeInsets.zero});

  final WakeWordService wakeWord;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: wakeWord,
      builder: (context, _) {
        if (!wakeWord.isListening) return const SizedBox.shrink();
        final style = Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600);
        return Padding(
          padding: padding,
          child: Semantics(
            container: true,
            label: 'Hey Child is listening for the wake phrase',
            excludeSemantics: true,
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                gradient: _navy,
                borderRadius: BorderRadius.circular(23),
                boxShadow: const [
                  BoxShadow(color: Color(0x406366F1), blurRadius: 18, spreadRadius: -6, offset: Offset(0, 6)),
                ],
              ),
              child: Row(
                children: [
                  const SizedBox(width: 72, height: 30, child: SiriWaveform(phase: WakeWordUiPhase.idle)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(WakeWordUiPhase.idle.label, style: style, overflow: TextOverflow.ellipsis)),
                  Icon(Icons.mic_none_rounded, size: 18, color: Colors.white.withValues(alpha: 0.7)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
