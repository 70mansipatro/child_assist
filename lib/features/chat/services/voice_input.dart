import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Speech input for Child Assist chat.
///
/// The flow is: tap the microphone → speech-to-text ([listen]) → the same `ChatSession.send`
/// used for typed messages → Gemini on the server → reply → optional text-to-speech. Only the
/// transcription step is new; the chat logic stays shared, and no audio ever leaves the device's
/// speech service: the app only receives text.
///
/// The microphone permission is checked by the caller (through the app's `PermissionService`)
/// before [listen]; implementations never ask for it on their own, and never listen unless
/// [listen] was called after a tap.
abstract class VoiceInput {
  /// Whether this build supports speech input at all. The microphone button stays visible
  /// either way; if this is false, tapping it explains that voice is not available.
  bool get isAvailable;

  /// True between [listen] and the end of that utterance.
  bool get isListening;

  /// Prepares the device speech service. Returns false if it is not available (e.g. no speech
  /// recognition service is installed). Safe to call more than once.
  Future<bool> initialize();

  /// Listens for one utterance and returns what was understood.
  ///
  /// Returns an empty string if nothing was heard, and null if [cancelListening] was called.
  /// [onPartialResult] receives the words recognised so far while the user is speaking.
  /// Throws [VoiceInputException] when recognition fails. Completes exactly once per call.
  Future<String?> listen({ValueChanged<String>? onPartialResult, String? localeId});

  /// Stops listening and lets [listen] complete with what was recognised so far.
  Future<void> stopListening();

  /// Stops listening and discards the utterance; [listen] completes with null.
  Future<void> cancelListening();

  /// The languages the device can recognise, for a future language picker.
  Future<List<VoiceLocale>> locales();

  /// Releases the speech service.
  Future<void> dispose();
}

/// A recognition language, e.g. `en_US` "English (United States)".
@immutable
class VoiceLocale {
  const VoiceLocale(this.id, this.name);

  final String id;
  final String name;
}

/// Why voice input failed. Each kind maps to a friendly message; raw platform errors are never
/// shown to the user.
enum VoiceErrorKind {
  permissionDenied,
  permissionBlocked,
  unavailable,

  /// The recogniser was asked to listen but never opened the microphone (e.g. the phone's
  /// speech service failed to start). Distinct from [noSpeech], where it listened to silence.
  notStarted,
  noSpeech,
  busy,
  network,
  unknown;

  String get message => switch (this) {
        permissionDenied => 'Microphone permission is needed for voice chat.',
        permissionBlocked =>
          'Microphone permission is needed for voice chat. You can turn it on in Permissions.',
        unavailable =>
          "Speech recognition isn't available on this device. You can type your message instead.",
        notStarted =>
          "Voice input couldn't start. Check that your phone's speech recognition (Google) is "
              'turned on, then try again.',
        noSpeech => "I didn't hear anything. Try again.",
        busy => 'The microphone is busy right now. Try again in a moment.',
        network => "I couldn't understand that because of a connection problem. Try again.",
        unknown => "Something went wrong with voice chat. Try again.",
      };
}

class VoiceInputException implements Exception {
  const VoiceInputException(this.kind);

  final VoiceErrorKind kind;

  @override
  String toString() => 'VoiceInputException(${kind.name})';
}

/// For builds without speech recognition. Never touches the microphone.
class UnavailableVoiceInput implements VoiceInput {
  const UnavailableVoiceInput();

  @override
  bool get isAvailable => false;

  @override
  bool get isListening => false;

  @override
  Future<bool> initialize() async => false;

  @override
  Future<String?> listen({ValueChanged<String>? onPartialResult, String? localeId}) async =>
      throw const VoiceInputException(VoiceErrorKind.unavailable);

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> cancelListening() async {}

  @override
  Future<List<VoiceLocale>> locales() async => const [];

  @override
  Future<void> dispose() async {}
}

/// Speech input through the device's own recogniser (`speech_to_text`): Google speech services
/// on Android, SFSpeechRecognizer on iOS. Tap-to-talk only: one [listen] per tap, never
/// continuous and never in the background.
class SpeechToTextVoiceInput implements VoiceInput {
  SpeechToTextVoiceInput({
    SpeechToText? speech,
    bool? isWeb,
    TargetPlatform? platform,
    this.listenFor = const Duration(seconds: 30),
    this.pauseFor = const Duration(seconds: 4),
    this.lookUpRecognizer = false,
  })  : _speechOverride = speech,
        _isWeb = isWeb ?? kIsWeb,
        _platform = platform ?? defaultTargetPlatform;

  // Created on first use, so the plugin is not touched until the user taps the microphone.
  final SpeechToText? _speechOverride;
  SpeechToText? _speechInstance;
  SpeechToText get _speech => _speechInstance ??= _speechOverride ?? SpeechToText();

  final bool _isWeb;
  final TargetPlatform _platform;

  /// The longest a single utterance may last.
  final Duration listenFor;

  /// How long a silence ends the utterance.
  final Duration pauseFor;

  /// Android: bind to the installed speech service by its component name instead of the
  /// phone's "default" recogniser, for phones whose default one does not work.
  final bool lookUpRecognizer;

  bool _initialized = false;
  Future<bool>? _initializing;
  Completer<String?>? _pending;
  String _recognized = '';
  ValueChanged<String>? _onPartial;

  // Evidence that this utterance really reached the microphone: the recogniser reported
  // "listening" and then sound levels or words. Without it, a "no match" means the recogniser
  // failed to start, not that the user was silent.
  bool _started = false;
  bool _heardAudio = false;

  @override
  bool get isAvailable =>
      !_isWeb && (_platform == TargetPlatform.android || _platform == TargetPlatform.iOS);

  @override
  bool get isListening => _pending != null;

  @override
  Future<bool> initialize() {
    if (!isAvailable) return Future.value(false);
    if (_initialized) return Future.value(true);
    // Concurrent callers share one platform initialisation.
    return _initializing ??= _initialize().whenComplete(() => _initializing = null);
  }

  Future<bool> _initialize() async {
    try {
      _initialized = await _speech.initialize(
        onError: _handleError,
        onStatus: _handleStatus,
        // Native plugin logs (tag SpeechToTextPlugin) in debug builds only.
        debugLogging: kDebugMode,
        // Bluetooth headsets would need an extra runtime permission; the phone's microphone
        // is enough for tap-to-talk.
        options: [
          SpeechToText.androidNoBluetooth,
          if (lookUpRecognizer) SpeechToText.androidIntentLookup,
        ],
      );
    } catch (e) {
      _log('speech initialize threw ${e.runtimeType}');
      _initialized = false;
    }
    _log('speech initialized: $_initialized');
    return _initialized;
  }

  @override
  Future<String?> listen({ValueChanged<String>? onPartialResult, String? localeId}) async {
    if (_pending != null) throw const VoiceInputException(VoiceErrorKind.busy);
    if (!await initialize()) throw const VoiceInputException(VoiceErrorKind.unavailable);

    final pending = _pending = Completer<String?>();
    _recognized = '';
    _onPartial = onPartialResult;
    _started = false;
    _heardAudio = false;
    try {
      await _speech.listen(
        onResult: _handleResult,
        onSoundLevelChange: _handleSoundLevel,
        listenOptions: SpeechListenOptions(
          listenFor: listenFor,
          pauseFor: pauseFor,
          // Null: the device's own speech language.
          localeId: localeId,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.confirmation,
        ),
      );
      // The recogniser reports "listening" before listen returns; without it, it refused to
      // start (e.g. a previous session was still open) and nothing would ever complete.
      if (!_started && !pending.isCompleted && !_speech.isListening) {
        _log('listen did not start');
        _completeError(const VoiceInputException(VoiceErrorKind.notStarted));
      } else {
        _log('listening started');
      }
    } catch (e) {
      _log('listen threw ${e.runtimeType}');
      _completeError(const VoiceInputException(VoiceErrorKind.notStarted));
    }
    return pending.future;
  }

  @override
  Future<void> stopListening() async {
    if (_pending == null) return;
    _log('stop requested');
    try {
      // The recogniser then sends its final result (or "done"), which completes [listen].
      await _speech.stop();
    } catch (e) {
      _log('stop threw ${e.runtimeType}');
      _complete(_recognized);
    }
  }

  @override
  Future<void> cancelListening() async {
    if (_pending == null) return;
    _log('cancelled');
    _complete(null);
    try {
      await _speech.cancel();
    } catch (e) {
      _log('cancel threw ${e.runtimeType}');
    }
  }

  @override
  Future<List<VoiceLocale>> locales() async {
    if (!await initialize()) return const [];
    try {
      return [for (final l in await _speech.locales()) VoiceLocale(l.localeId, l.name)];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> dispose() => cancelListening();

  void _handleResult(SpeechRecognitionResult result) {
    if (_pending == null) return;
    _recognized = result.recognizedWords;
    if (_recognized.isNotEmpty) _heardAudio = true;
    if (result.finalResult) {
      _log('final: ${_private(_recognized)}');
      _complete(_recognized);
    } else {
      _log('partial: ${_private(_recognized)}');
      _onPartial?.call(_recognized);
    }
  }

  void _handleSoundLevel(double level) {
    if (_pending != null) _heardAudio = true;
  }

  void _handleStatus(String status) {
    _log('status: $status');
    if (_pending == null) return;
    if (status == SpeechToText.listeningStatus) _started = true;
    // "done" without a final result (e.g. stopped during silence): use what was heard.
    if (status == SpeechToText.doneStatus) _complete(_recognized);
  }

  void _handleError(SpeechRecognitionError error) {
    _log('error: ${error.errorMsg}');
    if (_pending == null) return;
    var kind = errorKindFor(error.errorMsg);
    if (kind == VoiceErrorKind.noSpeech && !_heardAudio && _platform == TargetPlatform.android) {
      // Android reports sound levels the whole time it records, even in silence. With none at
      // all, the speech service never opened the microphone: that is not "no speech".
      kind = VoiceErrorKind.notStarted;
    }
    // Silence is not a failure: [listen] reports it as an empty transcript.
    if (kind == VoiceErrorKind.noSpeech) {
      _complete(_recognized);
    } else {
      _completeError(VoiceInputException(kind));
    }
  }

  /// Maps the plugin's error codes (see `speech_to_text`) to what the user is told.
  @visibleForTesting
  static VoiceErrorKind errorKindFor(String code) {
    switch (code) {
      case 'error_no_match':
      case 'error_speech_timeout':
        return VoiceErrorKind.noSpeech;
      case 'error_permission':
      case 'error_insufficient_permissions':
        return VoiceErrorKind.permissionDenied;
      case 'error_busy':
      case 'error_recognizer_busy':
      case 'error_audio_error':
        return VoiceErrorKind.busy;
      case 'error_network':
      case 'error_network_timeout':
      case 'error_server':
      case 'error_server_disconnected':
      case 'error_too_many_requests':
        return VoiceErrorKind.network;
      case 'error_language_not_supported':
      case 'error_language_unavailable':
      case 'error_speech_recognizer_disabled':
        return VoiceErrorKind.unavailable;
      case 'error_client':
        return VoiceErrorKind.notStarted;
      default:
        return VoiceErrorKind.unknown;
    }
  }

  // The recogniser can report a final result, "done" and an error for one utterance; only the
  // first of them completes [listen], so one tap can never produce two messages.
  void _complete(String? text) {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    _pending = null;
    _onPartial = null;
    pending.complete(text?.trim());
  }

  void _completeError(VoiceInputException error) {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    _pending = null;
    _onPartial = null;
    pending.completeError(error);
  }
}

/// Development-only voice logs: never tokens or personal data, and the recognised words only
/// in debug builds.
void _log(String message) {
  if (kDebugMode) debugPrint('[Voice] $message');
}

String _private(String words) => kDebugMode ? '"$words"' : '(${words.length} chars)';
