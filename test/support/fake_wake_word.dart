import 'dart:async';

import 'package:child_assist/features/voice_assistant/data/wake_word_platform.dart';

/// Stands in for the Android wake-word service. Like the real one, it keeps a set of reasons the
/// microphone is closed and listens only when none is left, closes the microphone itself when it
/// hears the phrase ("interaction"), and reports status changes as events.
class FakeWakeWordPlatform implements WakeWordPlatform {
  FakeWakeWordPlatform({this.isSupported = true});

  @override
  bool isSupported;

  /// Every call, in order, e.g. "start u1", "suspend speaking", "resume interaction", "stop".
  final List<String> calls = [];

  /// What `start` answers.
  WakeWordStartResult startResult = WakeWordStartResult.started;

  /// The phone's lock screen, and whether the user unlocks when asked.
  DeviceLockState lock = DeviceLockState.unlocked;
  bool unlockSucceeds = true;
  bool fullScreenAllowed = true;

  /// A wake phrase that opened the app before Flutter was running.
  bool pendingActivation = false;

  WakeWordTuning? tuning;
  bool showingOverLockScreen = false;
  bool screenKeptOn = false;

  final Set<String> suspended = {};
  NativeWakeStatus native = NativeWakeStatus.stopped;
  final _events = StreamController<WakeWordPlatformEvent>.broadcast();

  /// Someone (the app) is listening for events.
  bool get hasListener => _events.hasListener;

  bool get running => native.running;

  /// The microphone is open, waiting for the phrase.
  bool get listening => native.listening;

  @override
  Stream<WakeWordPlatformEvent> get events => _events.stream;

  @override
  Future<WakeWordStartResult> start({required String owner, required WakeWordTuning tuning}) async {
    calls.add('start $owner');
    this.tuning = tuning;
    if (startResult != WakeWordStartResult.started) {
      native = NativeWakeStatus(issue: startResult == WakeWordStartResult.startBlocked ? 'startBlocked' : null);
      return startResult;
    }
    _set(enabled: true, owner: owner, running: true);
    return startResult;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    suspended.clear();
    native = NativeWakeStatus.stopped;
    _events.add(WakeWordStatusEvent(native));
  }

  @override
  Future<void> suspend(String reason) async {
    calls.add('suspend $reason');
    if (!running) return;
    suspended.add(reason);
    _set();
  }

  @override
  Future<void> resume(String reason) async {
    calls.add('resume $reason');
    if (!running) return;
    suspended.remove(reason);
    _set();
  }

  @override
  Future<NativeWakeStatus> status() async => native;

  @override
  Future<bool> takeActivation() async {
    final pending = pendingActivation;
    pendingActivation = false;
    return pending;
  }

  @override
  Future<DeviceLockState> lockState() async => lock;

  @override
  Future<void> showOverLockScreen(bool show) async {
    calls.add('showOverLockScreen $show');
    showingOverLockScreen = show;
  }

  @override
  Future<void> keepScreenOn(bool on) async => screenKeptOn = on;

  /// Listening cues played (one per question, once the recogniser really listens).
  int cues = 0;

  @override
  Future<void> playCue() async {
    calls.add('cue');
    cues++;
  }

  @override
  Future<bool> requestUnlock() async {
    calls.add('requestUnlock');
    if (unlockSucceeds) lock = DeviceLockState.unlocked;
    return unlockSucceeds;
  }

  @override
  Future<bool> canUseFullScreenIntent() async => fullScreenAllowed;

  /// "Display over other apps" granted.
  bool backgroundOpenAllowed = true;

  @override
  Future<bool> canOpenFromBackground() async => backgroundOpenAllowed;

  @override
  Future<bool> openBackgroundOpenSettings() async {
    calls.add('openBackgroundOpenSettings');
    return true;
  }

  @override
  Future<bool> openFullScreenIntentSettings() async {
    calls.add('openFullScreenIntentSettings');
    return true;
  }

  /// Someone says "Hey Child". Like the phone, it is only heard while the microphone is open.
  /// Returns whether it was heard.
  /// [question]: asked in the same breath ("Hi Child, what is my name?"), heard by the phone.
  bool sayWakePhrase({String keyword = 'HEY_CHILD', String question = ''}) {
    if (!listening) return false;
    suspended.add('interaction');
    _set();
    _events.add(WakeWordDetectedEvent(keyword, question: question));
    return true;
  }

  /// The same phrase reported again (e.g. a second event in flight), regardless of the microphone.
  void repeatDetection({String keyword = 'HEY_CHILD'}) => _events.add(WakeWordDetectedEvent(keyword));

  /// The phone reports something on its own (a call started, the service failed...).
  void report(NativeWakeStatus status) {
    native = status;
    _events.add(WakeWordStatusEvent(status));
  }

  /// A call starts or ends (the phone closes the microphone during calls).
  void call(bool active) {
    if (active) {
      suspended.add('call');
    } else {
      suspended.remove('call');
    }
    _set();
  }

  void _set({bool? enabled, String? owner, bool? running}) {
    final isRunning = running ?? native.running;
    native = NativeWakeStatus(
      enabled: enabled ?? native.enabled,
      owner: owner ?? native.owner,
      running: isRunning,
      listening: isRunning && suspended.isEmpty,
      suspendedBy: suspended.toList(),
    );
    _events.add(WakeWordStatusEvent(native));
  }
}
