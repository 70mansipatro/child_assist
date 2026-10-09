import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/permissions/permission_service.dart';
import '../../auth/services/auth_service.dart';
import '../../chat/services/text_to_speech_service.dart';
import '../../permissions/services/permission_sync_service.dart';
import '../data/wake_word_platform.dart';
import '../data/wake_word_store.dart';
import '../models/wake_word_state.dart';

export '../data/wake_word_platform.dart' show WakeWordTuning;
export '../models/wake_word_state.dart';

/// "Hey Child": hands-free voice activation.
///
/// The wake phrase is detected on the phone by an offline keyword spotter in a foreground service
/// (Android). Until it is heard, no audio leaves the phone and none is stored. After it is heard,
/// the question is captured by the same speech recogniser as tap-to-talk and sent through the same
/// authenticated chat as a typed message; only the question's words are sent, never the phrase.
///
/// User-controlled and honest about its state:
/// - It runs only after the user switches it on and the OS grants the microphone. Status checks
///   never show a permission dialog; only [enable] (a user tap) does, once.
/// - [state] comes from what the phone reports, never just from the saved switch.
/// - It stops when the user switches it off (here or from its notification), logs out, switches
///   account, or the microphone permission is removed.
/// - It does not listen while Child Assist speaks, while the user talks with the microphone button,
///   or during calls, so it cannot wake itself.
class WakeWordService extends ChangeNotifier {
  WakeWordService({
    required AuthService authService,
    required PermissionService permissionService,
    required TextToSpeechService textToSpeech,
    PermissionSyncService? permissionSyncService,
    WakeWordPlatform? platform,
    WakeWordStore? store,
    this.tuning = const WakeWordTuning(),
    this.speechTail = const Duration(milliseconds: 700),
    this.micHandoffCooldown = const Duration(milliseconds: 300),
    this.activationTimeout = const Duration(seconds: 15),
    this.lockScreenGrace = const Duration(seconds: 15),
  })  : _auth = authService,
        _permissions = permissionService,
        _tts = textToSpeech,
        _permissionSync = permissionSyncService,
        _platform = platform ?? MethodChannelWakeWordPlatform(),
        _store = store ?? WakeWordStore() {
    _replies = _tts.repliesEnabled;
    _tts.addListener(_onSpeechChanged);
    _auth.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  final AuthService _auth;
  final PermissionService _permissions;
  final TextToSpeechService _tts;
  final PermissionSyncService? _permissionSync;
  final WakeWordPlatform _platform;
  final WakeWordStore _store;

  /// Internal detection tuning; not a user setting.
  final WakeWordTuning tuning;

  /// After a reply is read aloud, the wake word waits this long before listening again, so the
  /// tail of Child Assist's own voice is not heard.
  final Duration speechTail;

  /// After the phone's speech recogniser has released the microphone, the wake word waits this
  /// long before opening it again, so the two never record at the same time.
  final Duration micHandoffCooldown;

  /// How long a wake phrase waits for Child Assist to come on screen and take it.
  final Duration activationTimeout;

  /// How long answers stay above the lock screen after a question before the lock comes back.
  final Duration lockScreenGrace;

  /// The microphone is closed for the question itself, while a reply is read aloud, and during
  /// tap-to-talk. The phone tracks each reason separately.
  static const reasonInteraction = 'interaction';
  static const reasonSpeaking = 'speaking';
  static const reasonTalking = 'tapToTalk';

  /// The account everything below belongs to.
  String? _owner;

  /// Bumped on every switch-off and account change, so work started earlier never acts on the new
  /// state or another account.
  int _generation = 0;

  final _machine = WakeWordStateMachine();
  bool _enabled = false;
  bool _restoring = false;
  bool _enabling = false;
  WakeWordIssue? _issue;
  NativeWakeStatus _native = NativeWakeStatus.stopped;
  StreamSubscription<WakeWordPlatformEvent>? _events;

  bool _lockScreenAnswers = false;
  bool _notificationsBlocked = false;
  bool _fullScreenBlocked = false;
  bool _backgroundOpenBlocked = false;

  bool _pendingActivation = false;
  Timer? _activationTimer;
  bool _finishWhenSilent = false;
  bool _speaking = false;
  Timer? _speechTailTimer;
  Timer? _handoffTimer;
  bool _lockedSession = false;
  Timer? _lockTimer;

  bool _replies = false;
  bool _applyingReplies = false;
  bool _disposed = false;

  // ---------------------------------------------------------------------------------------------
  // What the screens show

  bool get isSupported => _platform.isSupported;

  /// The user's choice: switched on or off. Not the same as listening; see [state].
  bool get enabled => _enabled;

  WakeWordState get state => _machine.state;

  /// Why it is paused, failed or could not be switched on. Null when all is well.
  WakeWordIssue? get issue => _issue;

  /// Loading the saved choice, or asking for permission after a tap.
  bool get busy => _restoring || _enabling;

  /// Truly listening for the wake phrase right now.
  bool get isListening => state == WakeWordState.listeningForWakeWord;

  /// Whether answers may show above the lock screen without unlocking. Off by default.
  bool get lockScreenAnswers => _lockScreenAnswers;

  /// Android 13+: notifications are blocked, so the wake word's notification is hidden and it
  /// cannot open Child Assist over a locked or sleeping screen.
  bool get notificationsBlocked => _notificationsBlocked;

  /// Android 14+: "full screen notifications" are not allowed for Child Assist, so it cannot open
  /// over a locked or sleeping screen (a heads-up notification is shown instead).
  bool get fullScreenBlocked => _fullScreenBlocked;

  /// A wake phrase is waiting for the chat screen to take it ([takeActivation]).
  bool get hasPendingActivation => _pendingActivation;

  /// Child Assist is showing above the lock screen for a question. Only Chat is available; the rest
  /// of the app needs [unlock].
  bool get lockedSession => _lockedSession;

  /// One line for Settings, true to what the phone reports.
  String get statusMessage {
    if (!isSupported) return 'Wake Word is not available on this device.';
    switch (state) {
      case WakeWordState.disabled:
        return switch (_issue) {
          WakeWordIssue.permissionRequired || WakeWordIssue.permissionBlocked => 'Microphone permission is required.',
          _ => 'Wake Word is off.',
        };
      case WakeWordState.starting:
        return 'Starting Wake Word...';
      case WakeWordState.listeningForWakeWord:
        return 'Hey Child is listening for the wake phrase.';
      case WakeWordState.wakeWordDetected || WakeWordState.listeningForCommand:
        return 'Listening to your question...';
      case WakeWordState.processing:
        return 'Working on your answer...';
      case WakeWordState.speaking:
        return 'Answering...';
      case WakeWordState.paused:
        return switch (_issue) {
          WakeWordIssue.call => 'Paused during the call.',
          WakeWordIssue.microphoneBusy => 'Paused while another app uses the microphone.',
          WakeWordIssue.startBlocked =>
            'Paused. Android only lets Wake Word start while Child Assist is open on an unlocked screen; '
                'it starts as soon as it is.',
          _ => 'Paused while you talk to Child Assist.',
        };
      case WakeWordState.error:
        return switch (_issue) {
          WakeWordIssue.engine => "Wake Word couldn't start on this phone.",
          WakeWordIssue.microphone => "The microphone isn't available, so Wake Word stopped.",
          WakeWordIssue.unsupported => 'Wake Word is not available on this device.',
          _ => 'Wake Word stopped. Android or a battery saver closed it.',
        };
    }
  }

  // ---------------------------------------------------------------------------------------------
  // User actions

  /// Switches the wake word on. Call only from a user tap: this may show the OS microphone dialog
  /// (once; a blocked permission is never asked again here, see [openAppSettings]) and, on
  /// Android 13+, the notifications dialog. Never throws.
  Future<void> enable() async {
    final owner = _owner;
    if (owner == null || _enabling) return;
    if (!isSupported) {
      _issue = WakeWordIssue.unsupported;
      return _notify();
    }
    _enabling = true;
    final generation = ++_generation;
    _issue = null;
    _notify();
    try {
      var microphone = await _permissions.microphoneStatus();
      var asked = false;
      if (microphone == PermissionState.denied) {
        microphone = await _permissions.requestMicrophonePermission();
        asked = true;
      }
      unawaited(_report(AppPermission.microphone, microphone, fromRequest: asked));
      if (generation != _generation) return;
      if (!microphone.isUsable) {
        _enabled = false;
        _machine.reset();
        _issue = _permissionIssue(microphone);
        return;
      }

      // The notification shows that it is on, and is how it opens Child Assist on a locked phone.
      final notifications = await _permissions.requestNotificationPermission();
      unawaited(_report(AppPermission.notifications, notifications, fromRequest: true));
      if (generation != _generation) return;
      _notificationsBlocked = !notifications.isUsable && notifications != PermissionState.unavailable;

      _enabled = true;
      await _store.setEnabled(owner, true);
      if (generation != _generation) return;
      _machine.reset();
      _machine.fire(WakeWordEvent.enable);
      await _start(owner, generation);
      if (generation == _generation) await _refreshDeviceChecks();
    } finally {
      _enabling = false;
      _notify();
    }
  }

  /// Switches the wake word off: the microphone closes and the service and its notification go
  /// away at once.
  Future<void> disable() async {
    final owner = _owner;
    if (owner == null) return;
    _generation++;
    _enabled = false;
    _issue = null;
    await _stopEverything();
    await _store.setEnabled(owner, false);
    _notify();
  }

  /// Whether answers may show above the lock screen. Off: the user unlocks first.
  Future<void> setLockScreenAnswers(bool on) async {
    final owner = _owner;
    if (owner == null) return;
    _lockScreenAnswers = on;
    _notify();
    await _store.setLockScreenAnswers(owner, on);
  }

  /// Re-checks the phone after the app comes back to the foreground: stops if the microphone
  /// permission was removed, and starts listening again if Android had stopped it. Never shows a
  /// dialog.
  Future<void> recheck() async {
    final owner = _owner;
    if (owner == null || busy || !_enabled) return;
    final generation = _generation;
    // Mid-question the service is busy on purpose; it is checked once the question is done.
    if (_machine.inInteraction) return;
    await _ensureRunning(owner, generation);
    if (generation == _generation) await _refreshDeviceChecks();
  }

  Future<bool> openAppSettings() => _permissions.openSettings();

  Future<bool> openFullScreenSettings() => _platform.openFullScreenIntentSettings();

  /// "Display over other apps", so the wake phrase can open Child Assist while another app is used.
  Future<bool> openBackgroundOpenSettings() => _platform.openBackgroundOpenSettings();

  /// Without "Display over other apps", a wake phrase heard while another app is on screen shows a
  /// notification to tap instead of opening Child Assist by itself.
  bool get backgroundOpenBlocked => _backgroundOpenBlocked;

  // ---------------------------------------------------------------------------------------------
  // Tap-to-talk

  /// Closes the wake word's microphone while the user talks with the microphone button.
  Future<void> pauseFor(String reason) async {
    if (_enabled && isSupported) await _platform.suspend(reason);
  }

  Future<void> resumeAfter(String reason) async {
    if (isSupported) await _platform.resume(reason);
  }

  // ---------------------------------------------------------------------------------------------
  // A question after the wake phrase. Called by the chat screen's voice controller.

  /// True once per wake phrase: the chat screen takes it and listens for the question.
  bool takeActivation() {
    if (!_pendingActivation) return false;
    _pendingActivation = false;
    _activationTimer?.cancel();
    return true;
  }

  /// Gets the screen ready for the question: keeps it on, and handles a locked phone. With
  /// [lockScreenAnswers] on, Child Assist shows above the lock screen; otherwise the user is asked
  /// to unlock first. False if they did not, and nothing is asked.
  Future<bool> prepareForQuestion() async {
    final generation = _generation;
    unawaited(_platform.keepScreenOn(true));
    final lock = await _platform.lockState();
    if (generation != _generation) return false;
    if (!lock.locked) return true;
    if (_lockScreenAnswers) {
      _lockTimer?.cancel();
      _lockedSession = true;
      await _platform.showOverLockScreen(true);
      _notify();
      return true;
    }
    final unlocked = await _platform.requestUnlock();
    await _platform.showOverLockScreen(false);
    return unlocked && generation == _generation;
  }

  /// Whether the question may be taken while Child Assist is not on screen (another app, the Home
  /// screen, or the screen off). On an unlocked phone, yes. With the lock screen showing, only if
  /// the user switched on "Answer while locked"; otherwise nothing is asked or answered until they
  /// unlock and Child Assist comes up.
  Future<bool> mayListenInBackground() async {
    if (_lockScreenAnswers) return true;
    final lock = await _platform.lockState();
    return !lock.locked;
  }

  /// Whether an answer may be read aloud right now: never over the lock screen unless the user
  /// allowed answers there. (The phone may have locked while the answer was on its way.)
  Future<bool> mayRevealAnswer() async {
    if (_lockScreenAnswers || _lockedSession) return true;
    final lock = await _platform.lockState();
    return !lock.locked;
  }

  /// The recogniser started listening for the question.
  void commandListening() {
    if (!_machine.fire(WakeWordEvent.commandListening)) return;
    // Refreshes the phone's safety timeout for the question.
    unawaited(_platform.suspend(reasonInteraction));
    _notify();
  }

  /// The recogniser is really receiving audio: the cue tells the user to ask now. Played only now,
  /// not when the phrase is heard, because the recogniser needs about a second to start and
  /// words said before that are lost.
  void questionReady() {
    if (state != WakeWordState.listeningForCommand) return;
    _log('question recogniser receiving audio; cue');
    unawaited(_platform.playCue());
  }

  /// Fixed step names for the diagnostics log, never what was said or answered.
  void logStep(String step) => _log(step);

  /// A question was heard and is being sent.
  void commandHeard() {
    if (!_machine.fire(WakeWordEvent.commandHeard)) return;
    unawaited(_platform.suspend(reasonInteraction));
    _notify();
  }

  /// The answer arrived (or failed). Listening for the wake phrase resumes once it has been read
  /// aloud, if it is being read.
  void commandFinished() {
    if (_tts.isSpeaking) {
      _finishWhenSilent = true;
      _machine.fire(WakeWordEvent.replySpeaking);
      return _notify();
    }
    _endInteraction(WakeWordEvent.replyDone);
  }

  /// Nothing was asked after all (silence, timeout, cancelled, failed).
  void commandEnded() => _endInteraction(WakeWordEvent.commandEnded);

  /// "Unlock" during a lock-screen question: the rest of the app needs the phone unlocked.
  Future<bool> unlock() async {
    final unlocked = await _platform.requestUnlock();
    if (unlocked) await _endLockedSession();
    return unlocked;
  }

  /// The app left the screen: answers no longer stay above the lock screen.
  void appHidden() {
    if (_lockedSession) unawaited(_endLockedSession());
  }

  // ---------------------------------------------------------------------------------------------
  // Internals

  Future<void> _start(String owner, int generation) async {
    _listen();
    final result = await _platform.start(owner: owner, tuning: tuning);
    if (generation != _generation) return;
    switch (result) {
      case WakeWordStartResult.started:
        _apply(await _platform.status());
      case WakeWordStartResult.permission:
        await _turnOffForPermission(await _permissions.microphoneStatus());
      case WakeWordStartResult.startBlocked:
        _issue = WakeWordIssue.startBlocked;
        _machine.fire(WakeWordEvent.paused);
      case WakeWordStartResult.unsupported:
        _issue = WakeWordIssue.unsupported;
        _machine.fire(WakeWordEvent.failed);
    }
    _notify();
  }

  /// Starts the phone's service if it is not running for this account (e.g. Android stopped it),
  /// after checking the microphone permission (status only).
  Future<void> _ensureRunning(String owner, int generation) async {
    final microphone = await _permissions.microphoneStatus();
    if (generation != _generation) return;
    if (!microphone.isUsable) return _turnOffForPermission(microphone);
    _listen();
    final status = await _platform.status();
    if (generation != _generation) return;
    if (status.running && status.owner == owner) return _apply(status);
    if (!_machine.inInteraction && state != WakeWordState.starting) {
      _machine.reset();
      _machine.fire(WakeWordEvent.enable);
    }
    await _start(owner, generation);
  }

  void _listen() {
    if (_events != null || !isSupported) return;
    _events = _platform.events.listen(
      (event) => switch (event) {
        WakeWordStatusEvent(:final status) => _apply(status),
        WakeWordDetectedEvent(:final question) => _onDetected(question),
      },
      onError: (Object e) => debugPrint('[WakeWord] event error: ${e.runtimeType}'),
    );
  }

  /// Follows what the phone reports. During a question the question drives the state; only
  /// failures interrupt it.
  void _apply(NativeWakeStatus status) {
    _native = status;
    if (!_enabled || _disposed) return;
    final issue = status.issue;
    if (!status.running && issue != null) {
      switch (issue) {
        case 'permission':
          unawaited(_permissions.microphoneStatus().then(_turnOffForPermission));
          return;
        case 'startBlocked':
          _issue = WakeWordIssue.startBlocked;
          if (!_machine.fire(WakeWordEvent.paused)) _machine.fire(WakeWordEvent.failed);
        case 'engine':
          _issue = WakeWordIssue.engine;
          _machine.fire(WakeWordEvent.failed);
        default:
          _issue = WakeWordIssue.microphone;
          _machine.fire(WakeWordEvent.failed);
      }
      _cancelInteraction();
      return _notify();
    }
    // "Turn off" in the notification during a question ends the question too: the controller
    // sees the switch go off and closes the recogniser's microphone.
    if (_machine.inInteraction && (status.running || status.enabled)) return;
    if (!status.running) {
      if (_machine.inInteraction) _cancelInteraction();
      if (state == WakeWordState.starting) return;
      if (!status.enabled) {
        // Switched off from its notification ("Turn off").
        _enabled = false;
        _issue = null;
        _machine.fire(WakeWordEvent.disable);
        final owner = _owner;
        if (owner != null) unawaited(_store.setEnabled(owner, false));
        return _notify();
      }
      _issue = WakeWordIssue.stopped;
      _machine.fire(WakeWordEvent.failed);
      return _notify();
    }
    if (status.listening) {
      _issue = null;
      _machine.fire(WakeWordEvent.listening);
      return _notify();
    }
    final reason = status.suspendedBy.contains('call')
        ? WakeWordIssue.call
        : status.silenced
            ? WakeWordIssue.microphoneBusy
            : status.suspendedBy.any((r) => r == reasonTalking || r == reasonSpeaking)
                ? WakeWordIssue.talking
                : null;
    if (reason != null) {
      _issue = reason;
      _machine.fire(WakeWordEvent.paused);
    }
    _notify();
  }

  /// What was said with the phrase in the same breath, for the question that is about to start.
  String _inlineQuestion = '';

  /// Once per wake phrase: the question said together with it ("Hi Child, what is my name?"), or
  /// empty if the user waits for the cue to ask.
  String takeInlineQuestion() {
    final question = _inlineQuestion;
    _inlineQuestion = '';
    return question;
  }

  void _onDetected([String question = '']) {
    if (!_enabled || _owner == null) {
      unawaited(_platform.resume(reasonInteraction));
      return;
    }
    // The phone only reports the phrase while it was listening, even if a status update has not
    // arrived yet.
    if (!_machine.inInteraction && state != WakeWordState.listeningForWakeWord) {
      _machine.fire(WakeWordEvent.listening);
    }
    // Heard again while a question is in progress: one question at a time.
    if (!_machine.fire(WakeWordEvent.detected)) return;
    _issue = null;
    _inlineQuestion = question.trim();
    _pendingActivation = true;
    _activationTimer?.cancel();
    // If Child Assist never comes on screen (e.g. the notification was ignored), stop waiting.
    _activationTimer = Timer(activationTimeout, () {
      if (_pendingActivation) _endInteraction(WakeWordEvent.commandEnded);
    });
    _notify();
  }

  void _endInteraction(WakeWordEvent event) {
    _inlineQuestion = '';
    _finishWhenSilent = false;
    _pendingActivation = false;
    _activationTimer?.cancel();
    _machine.fire(event);
    unawaited(_platform.keepScreenOn(false));
    _handoffTimer?.cancel();
    if (event == WakeWordEvent.commandEnded && micHandoffCooldown > Duration.zero) {
      // The recogniser has only just let go of the microphone; reopen it shortly after.
      final generation = _generation;
      _handoffTimer = Timer(micHandoffCooldown, () {
        if (generation != _generation) return;
        _log('microphone back to the wake word');
        unawaited(_platform.resume(reasonInteraction));
      });
    } else {
      _log('microphone back to the wake word');
      unawaited(_platform.resume(reasonInteraction));
    }
    if (_lockedSession) {
      _lockTimer?.cancel();
      _lockTimer = Timer(lockScreenGrace, () => unawaited(_endLockedSession()));
    } else {
      // Opened over the lock screen by the phone but never used for a question.
      unawaited(_platform.showOverLockScreen(false));
    }
    _apply(_native);
    _notify();
  }

  void _cancelInteraction() {
    _inlineQuestion = '';
    _pendingActivation = false;
    _finishWhenSilent = false;
    _activationTimer?.cancel();
    unawaited(_platform.keepScreenOn(false));
  }

  Future<void> _endLockedSession() async {
    _lockTimer?.cancel();
    if (!_lockedSession) return;
    _lockedSession = false;
    _notify();
    await _platform.showOverLockScreen(false);
  }

  /// Child Assist's own voice must never wake it: the microphone closes while a reply is read
  /// aloud, and opens again shortly after it ends.
  void _onSpeechChanged() {
    final replies = _tts.repliesEnabled;
    if (replies != _replies) {
      _replies = replies;
      final owner = _owner;
      if (owner != null && !_applyingReplies) unawaited(_store.setVoiceReplies(owner, replies));
    }

    final speaking = _tts.isSpeaking;
    if (speaking == _speaking) return;
    _speaking = speaking;
    _speechTailTimer?.cancel();
    if (_enabled) _log(speaking ? 'tts started; wake word microphone closed' : 'tts finished');
    if (speaking) {
      if (_enabled && isSupported) unawaited(_platform.suspend(reasonSpeaking));
      if (_machine.fire(WakeWordEvent.replySpeaking)) _notify();
      return;
    }
    // With the wake word off there is nothing to reopen.
    if (!_enabled && !_finishWhenSilent) return;
    _speechTailTimer = Timer(speechTail, () {
      if (isSupported && _owner != null) unawaited(_platform.resume(reasonSpeaking));
      if (_finishWhenSilent) _endInteraction(WakeWordEvent.replyDone);
    });
  }

  Future<void> _turnOffForPermission(PermissionState microphone) async {
    final owner = _owner;
    _generation++;
    _enabled = false;
    await _stopEverything();
    _issue = _permissionIssue(microphone);
    if (owner != null) await _store.setEnabled(owner, false);
    _notify();
  }

  Future<void> _stopEverything() async {
    _cancelInteraction();
    _speechTailTimer?.cancel();
    _handoffTimer?.cancel();
    _machine.reset();
    // Not awaited: nothing depends on it, and it may complete in the listener's zone.
    unawaited(_events?.cancel());
    _events = null;
    _native = NativeWakeStatus.stopped;
    await _endLockedSession();
    if (isSupported) await _platform.stop();
  }

  Future<void> _refreshDeviceChecks() async {
    final notifications = await _permissions.notificationStatus();
    _notificationsBlocked = !notifications.isUsable && notifications != PermissionState.unavailable;
    _fullScreenBlocked = isSupported && !await _platform.canUseFullScreenIntent();
    _backgroundOpenBlocked = isSupported && !await _platform.canOpenFromBackground();
    _notify();
  }

  static WakeWordIssue _permissionIssue(PermissionState state) => switch (state) {
        PermissionState.permanentlyDenied || PermissionState.restricted => WakeWordIssue.permissionBlocked,
        PermissionState.unavailable => WakeWordIssue.unsupported,
        _ => WakeWordIssue.permissionRequired,
      };

  Future<void> _report(AppPermission permission, PermissionState state, {required bool fromRequest}) async {
    try {
      await _permissionSync?.report(permission, state, fromRequest: fromRequest);
    } catch (_) {
      // Best effort; the Permissions screen shows sync problems.
    }
  }

  // Login, logout, session expiry and account switches all arrive here. The wake word never
  // carries over from one account to the next: the previous account's listening stops at once.
  void _onAuthChanged() {
    final userId = _auth.currentUser?.id;
    if (userId == _owner) return;
    final previous = _owner;
    _generation++;
    _cancelInteraction();
    _speechTailTimer?.cancel();
    _handoffTimer?.cancel();
    _lockTimer?.cancel();
    unawaited(_events?.cancel());
    _events = null;
    _native = NativeWakeStatus.stopped;
    _machine.reset();
    _enabled = false;
    _restoring = false;
    _issue = null;
    _lockScreenAnswers = false;
    _notificationsBlocked = false;
    _fullScreenBlocked = false;
    _owner = userId;
    if (previous != null) {
      // Logging out switches it off for that account: after logging in again it stays off until
      // the user switches it on, so nothing listens without a fresh choice.
      unawaited(_store.setEnabled(previous, false));
      if (isSupported) {
        unawaited(_platform.stop());
        unawaited(_platform.keepScreenOn(false));
      }
      _lockedSession = false;
      unawaited(_platform.showOverLockScreen(false));
      // The previous account's voice choice and any speech end with it.
      unawaited(_tts.stop());
      _setReplies(false);
    }
    _notify();
    if (userId != null) unawaited(_restore(userId, _generation));
  }

  Future<void> _restore(String userId, int generation) async {
    _restoring = true;
    _notify();
    final enabled = await _store.isEnabled(userId);
    final lockScreen = await _store.lockScreenAnswers(userId);
    final replies = await _store.voiceReplies(userId);
    if (generation != _generation) return;
    _lockScreenAnswers = lockScreen;
    _setReplies(replies);

    final native = isSupported ? await _platform.status() : NativeWakeStatus.stopped;
    if (generation != _generation) return;
    // Left over from another account (or switched on from a previous install): never kept.
    if ((native.enabled || native.running) && native.owner != userId) await _platform.stop();
    if (generation != _generation) return;

    _restoring = false;
    if (!enabled || !isSupported) {
      if (!isSupported && enabled) _issue = WakeWordIssue.unsupported;
      return _notify();
    }
    if (!native.enabled && !native.running) {
      // The phone cleared it (and its owner): switched off from the notification, or the
      // permission was removed. A logout switches it off here too, so that is not this case.
      final microphone = await _permissions.microphoneStatus();
      if (generation != _generation) return;
      if (!microphone.isUsable) return _turnOffForPermission(microphone);
      await _store.setEnabled(userId, false);
      return _notify();
    }
    _enabled = true;
    _machine.fire(WakeWordEvent.enable);
    _notify();
    await _ensureRunning(userId, generation);
    if (generation != _generation || !_enabled) return;
    await _refreshDeviceChecks();
    // The wake phrase opened the app before it was running.
    if (generation == _generation && await _platform.takeActivation()) _onDetected();
  }

  void _setReplies(bool on) {
    _applyingReplies = true;
    try {
      _tts.repliesEnabled = on;
      _replies = _tts.repliesEnabled;
    } finally {
      _applyingReplies = false;
    }
  }

  WakeWordState? _loggedState;

  void _notify() {
    if (_disposed) return;
    if (state != _loggedState) {
      _loggedState = state;
      _log(switch (state) {
        WakeWordState.disabled => 'stopped',
        WakeWordState.starting => 'service starting',
        WakeWordState.listeningForWakeWord => 'listening',
        WakeWordState.wakeWordDetected => 'wake phrase detected',
        WakeWordState.listeningForCommand => 'question listening',
        WakeWordState.processing => 'processing',
        WakeWordState.speaking => 'speaking',
        WakeWordState.paused => 'paused (${_issue?.name})',
        WakeWordState.error => 'error (${_issue?.name})',
      });
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _auth.removeListener(_onAuthChanged);
    _tts.removeListener(_onSpeechChanged);
    _activationTimer?.cancel();
    _speechTailTimer?.cancel();
    _handoffTimer?.cancel();
    _lockTimer?.cancel();
    unawaited(_events?.cancel());
    super.dispose();
  }
}

/// Debug builds only. Fixed state names and issue kinds; never what the user said, tokens or ids.
void _log(String event) {
  if (kDebugMode) debugPrint('[WakeWord] $event');
}
