import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How eagerly the wake phrase is accepted. Internal tuning for the on-device keyword spotter;
/// never shown to users. See `WakeWordTuning` in the Android `WakeWordDetector` for how the defaults
/// were measured. The phone clamps both values to a safe range.
@immutable
class WakeWordTuning {
  const WakeWordTuning({this.threshold = 0.20, this.boost = 1.0});

  /// Stricter (fewer false activations, more missed phrases) as it goes up.
  final double threshold;
  final double boost;

  Map<String, double> toMap() => {'threshold': threshold, 'boost': boost};
}

/// What the phone's listening service reports.
@immutable
class NativeWakeStatus {
  const NativeWakeStatus({
    this.enabled = false,
    this.owner,
    this.running = false,
    this.listening = false,
    this.silenced = false,
    this.suspendedBy = const [],
    this.issue,
  });

  factory NativeWakeStatus.fromMap(Map<Object?, Object?> map) => NativeWakeStatus(
        enabled: map['enabled'] == true,
        owner: map['owner'] as String?,
        running: map['running'] == true,
        listening: map['listening'] == true,
        silenced: map['silenced'] == true,
        suspendedBy: [for (final r in (map['suspendedBy'] as List?) ?? const []) r as String],
        issue: map['issue'] as String?,
      );

  /// Switched on on the phone (it survives the app being closed).
  final bool enabled;

  /// The account that switched it on.
  final String? owner;

  /// The foreground service is running.
  final bool running;

  /// The microphone is open, waiting for the phrase.
  final bool listening;

  /// Another app or a call has taken the microphone; our audio is silent until it is released.
  final bool silenced;

  /// Why the microphone is closed for now, e.g. "speaking", "call", "interaction".
  final List<String> suspendedBy;

  /// Why it stopped: "permission", "startBlocked", "engine", "microphone"; null if fine.
  final String? issue;

  static const stopped = NativeWakeStatus();
}

sealed class WakeWordPlatformEvent {
  const WakeWordPlatformEvent();
}

class WakeWordStatusEvent extends WakeWordPlatformEvent {
  const WakeWordStatusEvent(this.status);

  final NativeWakeStatus status;
}

class WakeWordDetectedEvent extends WakeWordPlatformEvent {
  const WakeWordDetectedEvent(this.keyword);

  /// "HEY_CHILD" or "HI_CHILD".
  final String keyword;
}

enum WakeWordStartResult { started, permission, startBlocked, unsupported }

/// The phone's lock screen.
@immutable
class DeviceLockState {
  const DeviceLockState({required this.locked, required this.secure});

  /// The lock screen is showing.
  final bool locked;

  /// It needs a PIN, pattern, password or biometric to unlock.
  final bool secure;

  static const unlocked = DeviceLockState(locked: false, secure: false);
}

/// The on-device wake word and the window controls a voice question needs. Android only: the
/// wake word runs as a foreground service with its own notification (see `WakeWordService.kt`).
abstract class WakeWordPlatform {
  bool get isSupported;

  /// Status changes and wake phrases heard. Listen only while the wake word is switched on.
  Stream<WakeWordPlatformEvent> get events;

  /// Starts listening for [owner]. Call only while the app is on screen: Android does not let a
  /// microphone service start from the background.
  Future<WakeWordStartResult> start({required String owner, required WakeWordTuning tuning});

  /// Stops listening and forgets the switch and the account on the phone.
  Future<void> stop();

  /// Closes the microphone for [reason] until [resume] with the same reason.
  Future<void> suspend(String reason);
  Future<void> resume(String reason);

  Future<NativeWakeStatus> status();

  /// True once if the wake phrase opened the app and no one has handled it yet.
  Future<bool> takeActivation();

  Future<DeviceLockState> lockState();

  /// Shows Child Assist above the lock screen (and turns the screen on) during a question.
  Future<void> showOverLockScreen(bool show);

  /// Keeps the screen from turning off during a question (a window flag, not a wake lock).
  Future<void> keepScreenOn(bool on);

  /// Asks the user to unlock the phone. True once unlocked.
  Future<bool> requestUnlock();

  /// Android 14+ can withhold the full-screen notification that opens the app on a locked phone.
  Future<bool> canUseFullScreenIntent();
  Future<bool> openFullScreenIntentSettings();
}

/// The Android implementation, over "child_assist/wake_word". Never throws: a missing or failing
/// platform side reports "not running" / "unsupported".
class MethodChannelWakeWordPlatform implements WakeWordPlatform {
  MethodChannelWakeWordPlatform({bool? isWeb, TargetPlatform? platform})
      : _isWeb = isWeb ?? kIsWeb,
        _platform = platform ?? defaultTargetPlatform;

  final bool _isWeb;
  final TargetPlatform _platform;

  static const _channel = MethodChannel('child_assist/wake_word');
  static const _events = EventChannel('child_assist/wake_word/events');

  @override
  bool get isSupported => !_isWeb && _platform == TargetPlatform.android;

  @override
  late final Stream<WakeWordPlatformEvent> events = isSupported
      ? _events.receiveBroadcastStream().map(_parse).where((e) => e != null).cast<WakeWordPlatformEvent>()
      : const Stream.empty();

  static WakeWordPlatformEvent? _parse(Object? raw) {
    if (raw is! Map) return null;
    return switch (raw['type']) {
      'status' => WakeWordStatusEvent(NativeWakeStatus.fromMap(raw)),
      'detected' => WakeWordDetectedEvent(raw['keyword'] as String? ?? ''),
      _ => null,
    };
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? arguments]) async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      debugPrint('[WakeWord] $method failed: ${e.code}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<WakeWordStartResult> start({required String owner, required WakeWordTuning tuning}) async {
    if (!isSupported) return WakeWordStartResult.unsupported;
    return switch (await _call<String>('start', {'owner': owner, 'tuning': tuning.toMap()})) {
      'started' => WakeWordStartResult.started,
      'permission' => WakeWordStartResult.permission,
      'startBlocked' => WakeWordStartResult.startBlocked,
      _ => WakeWordStartResult.unsupported,
    };
  }

  @override
  Future<void> stop() => _call<void>('stop');

  @override
  Future<void> suspend(String reason) => _call<void>('suspend', {'reason': reason});

  @override
  Future<void> resume(String reason) => _call<void>('resume', {'reason': reason});

  @override
  Future<NativeWakeStatus> status() async {
    final map = await _call<Map<Object?, Object?>>('status');
    return map == null ? NativeWakeStatus.stopped : NativeWakeStatus.fromMap(map);
  }

  @override
  Future<bool> takeActivation() async => await _call<bool>('takeActivation') ?? false;

  @override
  Future<DeviceLockState> lockState() async {
    final map = await _call<Map<Object?, Object?>>('lockState');
    if (map == null) return DeviceLockState.unlocked;
    return DeviceLockState(locked: map['locked'] == true, secure: map['secure'] == true);
  }

  @override
  Future<void> showOverLockScreen(bool show) => _call<void>('showOverLockScreen', {'show': show});

  @override
  Future<void> keepScreenOn(bool on) => _call<void>('keepScreenOn', {'on': on});

  @override
  Future<bool> requestUnlock() async => await _call<bool>('requestUnlock') ?? false;

  @override
  Future<bool> canUseFullScreenIntent() async => await _call<bool>('canUseFullScreenIntent') ?? true;

  @override
  Future<bool> openFullScreenIntentSettings() async => await _call<bool>('openFullScreenIntentSettings') ?? false;
}
