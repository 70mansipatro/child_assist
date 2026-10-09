import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/wake_word_ui_state.dart';

/// A glowing, multicolour voice waveform (cyan, electric blue, indigo, violet, pink), inspired by
/// Siri. Meant for a dark background.
///
/// Its height follows the microphone only while [phase] is [WakeWordUiPhase.listening] and [level]
/// reports real loudness. Every other phase (and listening before any level arrives) uses a calm,
/// fixed motion that does not pretend to be audio.
///
/// Efficient by design: one ticker that only repaints (no rebuilds), paused by [TickerMode] (e.g. a
/// hidden tab) and not running at all with the OS "reduce motion" setting, where a still wave is
/// drawn instead.
class SiriWaveform extends StatefulWidget {
  const SiriWaveform({super.key, required this.phase, this.level});

  final WakeWordUiPhase phase;

  /// Real microphone loudness (0 to 1), or null when none is known.
  final ValueListenable<double?>? level;

  /// How tall the wave is for [phase] (0 to 1) when no loudness is known.
  @visibleForTesting
  static double restingAmplitude(WakeWordUiPhase phase) => switch (phase) {
        WakeWordUiPhase.idle => 0.16,
        WakeWordUiPhase.wakeWordDetected => 0.85,
        WakeWordUiPhase.listening => 0.24,
        WakeWordUiPhase.processing => 0.42,
        WakeWordUiPhase.speaking => 0.6,
        WakeWordUiPhase.error => 0.08,
      };

  /// How tall the wave is for [phase], following [level] when it is real loudness of the question.
  @visibleForTesting
  static double targetAmplitude(WakeWordUiPhase phase, double? level) =>
      phase == WakeWordUiPhase.listening && level != null ? 0.1 + 0.9 * level.clamp(0.0, 1.0) : restingAmplitude(phase);

  @override
  State<SiriWaveform> createState() => _SiriWaveformState();
}

class _SiriWaveformState extends State<SiriWaveform> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final _WaveFrame _frame = _WaveFrame(widget.phase, _target);
  Duration _last = Duration.zero;
  bool _still = false;

  double get _target => SiriWaveform.targetAmplitude(widget.phase, widget.level?.value);

  @override
  void initState() {
    super.initState();
    widget.level?.addListener(_levelChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_still) {
      _ticker.stop();
      _frame.settle(_target);
    } else if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(SiriWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level != widget.level) {
      oldWidget.level?.removeListener(_levelChanged);
      widget.level?.addListener(_levelChanged);
    }
    _frame.phase = widget.phase;
    if (_still) _frame.settle(_target);
  }

  void _levelChanged() {
    if (_still) _frame.settle(_target);
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    // Eases towards the target, so loudness changes and phase changes never jump.
    final ease = 1 - math.exp(-dt * 9);
    _frame
      ..time += dt * _speed(widget.phase)
      ..amplitude += (_target - _frame.amplitude) * ease
      ..repaint();
  }

  static double _speed(WakeWordUiPhase phase) => switch (phase) {
        WakeWordUiPhase.idle => 0.7,
        WakeWordUiPhase.wakeWordDetected => 2.0,
        WakeWordUiPhase.listening => 1.6,
        WakeWordUiPhase.processing => 2.8,
        WakeWordUiPhase.speaking => 2.0,
        WakeWordUiPhase.error => 0.4,
      };

  @override
  void dispose() {
    widget.level?.removeListener(_levelChanged);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(painter: _SiriWavePainter(_frame), size: Size.infinite),
      ),
    );
  }
}

/// What one frame of the wave looks like. Repaints the painter without rebuilding widgets.
class _WaveFrame extends ChangeNotifier {
  _WaveFrame(this.phase, this.amplitude);

  WakeWordUiPhase phase;
  double amplitude;

  /// Seconds of wave motion so far (scaled by the phase's speed).
  double time = 1.3;

  void settle(double target) {
    amplitude = target;
    repaint();
  }

  void repaint() => notifyListeners();
}

/// Draws the wave: five glowing, overlapping lobes that taper to a thin line at both ends.
class _SiriWavePainter extends CustomPainter {
  _SiriWavePainter(this._frame) : super(repaint: _frame);

  final _WaveFrame _frame;

  static const colors = <Color>[
    Color(0xFF22D3EE), // cyan
    Color(0xFF3B82F6), // electric blue
    Color(0xFF6366F1), // indigo
    Color(0xFF8B5CF6), // violet
    Color(0xFFEC4899), // pink
  ];
  static const _frequency = [1.5, 2.2, 1.15, 1.9, 1.35];
  static const _speed = [1.0, 1.35, 0.8, 1.6, 1.15];
  static const _offset = [0.0, 1.1, 2.3, 3.6, 4.7];
  static const _scale = [0.9, 0.72, 1.0, 0.82, 0.66];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width;
    final mid = size.height / 2;
    final t = _frame.time;
    final amplitude = _frame.amplitude * _modulation(_frame.phase, t);
    final maxHeight = size.height / 2 * 0.92;

    // Thin resting line, brightest in the middle; fades as the wave grows.
    final line = Paint()
      ..strokeWidth = 1.2
      ..shader = LinearGradient(colors: [
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: (0.55 - amplitude * 0.4).clamp(0.12, 0.55)),
        Colors.white.withValues(alpha: 0),
      ]).createShader(Offset.zero & size);
    canvas.drawLine(Offset(w * 0.04, mid), Offset(w * 0.96, mid), line);

    final glow = Paint()
      ..blendMode = BlendMode.screen
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(2, size.height * 0.1));
    final fill = Paint()..blendMode = BlendMode.screen;
    for (var i = 0; i < colors.length; i++) {
      // Each lobe breathes on its own, so the wave looks organic rather than mechanical.
      final breathe = 0.55 + 0.45 * math.sin(t * 0.45 * (i + 1) + _offset[i]);
      final height = amplitude * _scale[i] * breathe * maxHeight;
      if (height < 0.5) continue;
      final path = _lobe(w, mid, height, _frequency[i], t * _speed[i] + _offset[i]);
      canvas.drawPath(path, glow..color = colors[i].withValues(alpha: 0.5));
      canvas.drawPath(path, fill..color = colors[i].withValues(alpha: 0.62));
    }
  }

  /// A slow, regular rhythm for the phases with no real audio level, so "thinking" and
  /// "answering" look alive without claiming to follow a voice.
  static double _modulation(WakeWordUiPhase phase, double t) => switch (phase) {
        WakeWordUiPhase.processing => 0.7 + 0.3 * math.sin(t * 1.7),
        WakeWordUiPhase.speaking => 0.72 + 0.28 * math.sin(t * 2.6) * math.cos(t * 1.1),
        _ => 1,
      };

  static Path _lobe(double width, double mid, double height, double frequency, double phase) {
    final steps = math.max(24, width ~/ 4);
    final ys = List<double>.generate(steps + 1, (j) {
      final x = j / steps * 4 - 2; // -2..2
      final taper = math.pow(4 / (4 + math.pow(x, 4)), 2).toDouble();
      return taper * height * math.sin(frequency * x * math.pi - phase);
    });
    final path = Path()..moveTo(0, mid);
    for (var j = 0; j <= steps; j++) {
      path.lineTo(width * j / steps, mid - ys[j]);
    }
    for (var j = steps; j >= 0; j--) {
      path.lineTo(width * j / steps, mid + ys[j]);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_SiriWavePainter oldDelegate) => oldDelegate._frame != _frame;
}
