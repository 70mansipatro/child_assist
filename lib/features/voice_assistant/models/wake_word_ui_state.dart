import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/wake_word_service.dart';

/// What the "Hey Child" waveform shows. Derived only from the real [WakeWordService] state; the UI
/// never invents a state of its own.
enum WakeWordUiPhase {
  /// Listening for the wake phrase: a calm waveform and "Say “Hey Child”".
  idle,

  /// The wake phrase was just heard: the waveform expands.
  wakeWordDetected,

  /// The phone's recogniser listens to the question.
  listening,

  /// The question was sent; waiting for the answer.
  processing,

  /// The answer is being read aloud.
  speaking,

  /// Something went wrong; shown briefly with a helpful message.
  error;

  /// The main line shown for this phase (the error message replaces it for [error]).
  String get label => switch (this) {
        idle => 'Say “Hey Child”',
        wakeWordDetected => "Hi! I'm here",
        listening => "I'm listening…",
        processing => 'Thinking…',
        speaking => 'Answering…',
        error => 'Something went wrong',
      };

  /// The smaller line under [label], if any.
  String? get hint => switch (this) {
        wakeWordDetected => 'Get ready to ask your question',
        listening => 'Ask your question now',
        processing => 'Finding your answer',
        speaking => 'Listen to my answer',
        idle || error => null,
      };

  /// A question started by the wake phrase is in progress.
  bool get isInteraction => switch (this) {
        wakeWordDetected || listening || processing || speaking => true,
        idle || error => false,
      };

  /// The waveform's phase for [state], or null when there is nothing to show (switched off,
  /// starting, or paused for a call or tap-to-talk).
  static WakeWordUiPhase? forState(WakeWordState state) => switch (state) {
        WakeWordState.listeningForWakeWord => idle,
        WakeWordState.wakeWordDetected => wakeWordDetected,
        WakeWordState.listeningForCommand => listening,
        WakeWordState.processing => processing,
        WakeWordState.speaking => speaking,
        WakeWordState.error => error,
        WakeWordState.disabled || WakeWordState.starting || WakeWordState.paused => null,
      };
}

/// Follows [WakeWordService] and says what the waveform shows: the [phase] and its [message].
///
/// Errors are shown for [errorDuration], then the waveform goes back to what the service reports
/// (listening for the wake phrase again, when it resumed). A failed question ([WakeWordService.questionProblem])
/// and the service entering [WakeWordState.error] both count; a new question replaces an error at once.
class WakeWordUiController extends ChangeNotifier {
  WakeWordUiController(this._wake, {this.errorDuration = const Duration(seconds: 4)}) {
    _seenProblem = _wake.questionProblem;
    _wake.addListener(_update);
    _update();
  }

  final WakeWordService _wake;
  final Duration errorDuration;

  WakeWordUiPhase? _phase;
  String? _error;
  Timer? _errorTimer;
  WakeWordProblem? _seenProblem;
  WakeWordState? _lastState;

  WakeWordUiPhase? get phase => _phase;

  /// What to say for [phase].
  String get message => _phase == WakeWordUiPhase.error ? (_error ?? WakeWordUiPhase.error.label) : (_phase?.label ?? '');

  /// The headline: [message], or "Oops!" above an error's message.
  String get title => _phase == WakeWordUiPhase.error ? 'Oops!' : message;

  /// The line under [title]: the error's message, or the phase's hint.
  String? get detail => _phase == WakeWordUiPhase.error ? message : _phase?.hint;

  /// The real loudness of the question while it is being asked; null when unknown.
  ValueListenable<double?> get level => _wake.questionLevel;

  void _update() {
    final state = _wake.state;
    final base = WakeWordUiPhase.forState(state);

    final problem = _wake.questionProblem;
    if (problem != null && !identical(problem, _seenProblem)) {
      _seenProblem = problem;
      _showError(problem.message);
    }
    if (state == WakeWordState.error && _lastState != WakeWordState.error) _showError(_wake.statusMessage);
    _lastState = state;

    // A new question, or switched off: the old error no longer applies.
    if ((base?.isInteraction ?? false) || state == WakeWordState.disabled) _clearError();

    final next = _error != null
        ? WakeWordUiPhase.error
        : base == WakeWordUiPhase.error
            ? null // Already shown for [errorDuration]; Settings keeps explaining it.
            : base;
    final before = (_phase, _shownMessage);
    _phase = next;
    _shownMessage = message;
    if (before != (_phase, _shownMessage)) notifyListeners();
  }

  String _shownMessage = '';

  void _showError(String message) {
    _error = message;
    _errorTimer?.cancel();
    _errorTimer = Timer(errorDuration, () {
      _error = null;
      _update();
    });
  }

  void _clearError() {
    _errorTimer?.cancel();
    _error = null;
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    _wake.removeListener(_update);
    super.dispose();
  }
}
