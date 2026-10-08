/// Where "Hey Child" is. Exactly one at a time; see [WakeWordStateMachine] for the transitions.
enum WakeWordState {
  /// The user has not switched it on (or it was switched off).
  disabled,

  /// Switched on; the phone's listening service is starting.
  starting,

  /// The microphone is open on the phone, waiting only for the wake phrase.
  listeningForWakeWord,

  /// The wake phrase was just heard; Child Assist is opening to listen for the question.
  wakeWordDetected,

  /// The phone's speech recogniser is listening to the question.
  listeningForCommand,

  /// The question was sent; Child Assist is working on the answer.
  processing,

  /// The answer is being read aloud. The wake word does not listen meanwhile, so Child Assist
  /// cannot wake itself.
  speaking,

  /// Switched on, but not listening right now for a reason that clears by itself (a call,
  /// another app using the microphone, tap-to-talk), or until the app is opened again.
  paused,

  /// Switched on, but it cannot listen; [WakeWordIssue] says why.
  error,
}

/// What can happen to the wake word. Inputs to [WakeWordStateMachine].
enum WakeWordEvent {
  /// The user switched it on (or asked to try again).
  enable,

  /// The phone reports the microphone open and waiting for the phrase.
  listening,

  /// The phone reports listening paused (call, microphone in use, tap-to-talk...).
  paused,

  /// The phone reports it cannot listen (permission removed, microphone failed, stopped).
  failed,

  /// The wake phrase was heard.
  detected,

  /// The recogniser started listening for the question.
  commandListening,

  /// A question was heard and sent.
  commandHeard,

  /// No question after all: silence, timeout, cancelled, or the app was never opened.
  commandEnded,

  /// The answer started being read aloud.
  replySpeaking,

  /// The answer is complete (and finished being read aloud, if it was).
  replyDone,

  /// The user switched it off, logged out, or the permission was removed.
  disable,
}

/// Why the wake word is paused or failed. Each kind maps to a message for the user.
enum WakeWordIssue {
  /// Microphone permission is not granted; the OS may still ask.
  permissionRequired,

  /// Microphone permission was blocked; only the phone's Settings can change it.
  permissionBlocked,

  /// This device or build has no wake word (web, desktop, iOS).
  unsupported,

  /// Android did not let the listening service start in the background. Opening the app fixes it.
  startBlocked,

  /// The on-device wake-word model could not be loaded.
  engine,

  /// The microphone stopped working and could not be reopened.
  microphone,

  /// Another app (or a call) is using the microphone; listening resumes by itself.
  microphoneBusy,

  /// Paused during a phone or video call.
  call,

  /// Paused while the user talks to Child Assist with the microphone button.
  talking,

  /// The listening service stopped unexpectedly (e.g. the phone's battery saver).
  stopped,
}

/// The wake word's state transitions. Deterministic: the same state and event always give the same
/// result, and an event that does not apply leaves the state unchanged (e.g. hearing the phrase
/// again while a question is already being answered).
class WakeWordStateMachine {
  WakeWordState _state = WakeWordState.disabled;

  WakeWordState get state => _state;

  /// True while a question started by the wake phrase is in progress.
  bool get inInteraction => isInteraction(_state);

  static bool isInteraction(WakeWordState state) => switch (state) {
        WakeWordState.wakeWordDetected ||
        WakeWordState.listeningForCommand ||
        WakeWordState.processing ||
        WakeWordState.speaking =>
          true,
        _ => false,
      };

  /// Applies [event]. Returns false, leaving the state unchanged, if it does not apply.
  bool fire(WakeWordEvent event) {
    final next = transition(_state, event);
    if (next == null) return false;
    _state = next;
    return true;
  }

  /// Back to [WakeWordState.disabled] regardless of the current state (logout, account switch).
  void reset() => _state = WakeWordState.disabled;

  /// The state after [event] in [state], or null if [event] does not apply there.
  static WakeWordState? transition(WakeWordState state, WakeWordEvent event) {
    if (event == WakeWordEvent.disable) return state == WakeWordState.disabled ? null : WakeWordState.disabled;
    return switch ((state, event)) {
      (WakeWordState.disabled, WakeWordEvent.enable) => WakeWordState.starting,

      (WakeWordState.starting, WakeWordEvent.listening) => WakeWordState.listeningForWakeWord,
      (WakeWordState.starting, WakeWordEvent.paused) => WakeWordState.paused,
      (WakeWordState.starting, WakeWordEvent.failed) => WakeWordState.error,

      (WakeWordState.listeningForWakeWord, WakeWordEvent.detected) => WakeWordState.wakeWordDetected,
      (WakeWordState.listeningForWakeWord, WakeWordEvent.paused) => WakeWordState.paused,
      (WakeWordState.listeningForWakeWord, WakeWordEvent.failed) => WakeWordState.error,

      (WakeWordState.wakeWordDetected, WakeWordEvent.commandListening) => WakeWordState.listeningForCommand,
      (WakeWordState.wakeWordDetected, WakeWordEvent.commandEnded) => WakeWordState.listeningForWakeWord,
      (WakeWordState.wakeWordDetected, WakeWordEvent.failed) => WakeWordState.error,

      (WakeWordState.listeningForCommand, WakeWordEvent.commandHeard) => WakeWordState.processing,
      (WakeWordState.listeningForCommand, WakeWordEvent.commandEnded) => WakeWordState.listeningForWakeWord,
      (WakeWordState.listeningForCommand, WakeWordEvent.failed) => WakeWordState.error,

      (WakeWordState.processing, WakeWordEvent.replySpeaking) => WakeWordState.speaking,
      (WakeWordState.processing, WakeWordEvent.replyDone) => WakeWordState.listeningForWakeWord,
      (WakeWordState.processing, WakeWordEvent.commandEnded) => WakeWordState.listeningForWakeWord,
      (WakeWordState.processing, WakeWordEvent.failed) => WakeWordState.error,

      (WakeWordState.speaking, WakeWordEvent.replyDone) => WakeWordState.listeningForWakeWord,
      (WakeWordState.speaking, WakeWordEvent.commandEnded) => WakeWordState.listeningForWakeWord,
      (WakeWordState.speaking, WakeWordEvent.failed) => WakeWordState.error,

      (WakeWordState.paused, WakeWordEvent.listening) => WakeWordState.listeningForWakeWord,
      (WakeWordState.paused, WakeWordEvent.enable) => WakeWordState.starting,
      (WakeWordState.paused, WakeWordEvent.failed) => WakeWordState.error,

      (WakeWordState.error, WakeWordEvent.enable) => WakeWordState.starting,
      (WakeWordState.error, WakeWordEvent.listening) => WakeWordState.listeningForWakeWord,

      _ => null,
    };
  }
}
