import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/permissions/permission_service.dart';
import '../../permissions/services/permission_sync_service.dart';
import '../models/chat_message.dart';
import 'text_to_speech_service.dart';
import 'voice_input.dart';

/// Where a voice interaction is. Exactly one at a time.
enum VoiceState { idle, requestingPermission, listening, processing, speaking, error }

/// Tap-to-talk for the chat screen: checks the microphone permission, listens for one
/// utterance, sends the transcript through the normal chat send, and reads replies aloud when
/// "Voice replies" is on. The screen only draws [state]; all voice logic lives here.
class VoiceChatController extends ChangeNotifier {
  VoiceChatController({
    required VoiceInput voiceInput,
    required TextToSpeechService textToSpeech,
    required PermissionService permissionService,
    required PermissionSyncService permissionSyncService,
    required Future<ChatMessage?> Function(String text) send,
    required Future<bool> Function() explainPermission,
  })  : _voice = voiceInput,
        _tts = textToSpeech,
        _permissions = permissionService,
        _sync = permissionSyncService,
        _send = send,
        _explainPermission = explainPermission {
    _tts.addListener(_ttsChanged);
  }

  final VoiceInput _voice;
  final TextToSpeechService _tts;
  final PermissionService _permissions;
  final PermissionSyncService _sync;

  /// The chat's own send; returns the reply, or null if the turn failed.
  final Future<ChatMessage?> Function(String text) _send;

  /// Shows why the microphone is needed before the OS dialog; true if the user continues.
  final Future<bool> Function() _explainPermission;

  VoiceState _state = VoiceState.idle;
  String _transcript = '';
  VoiceErrorKind? _error;
  String? _speakingMessageId;
  bool _disposed = false;

  VoiceState get state {
    if (_state == VoiceState.idle && _tts.isSpeaking) return VoiceState.speaking;
    return _state;
  }

  /// The words recognised so far while listening.
  String get transcript => _transcript;

  /// Set while [state] is [VoiceState.error].
  VoiceErrorKind? get error => _error;

  /// The reply currently being read aloud, if any.
  String? get speakingMessageId => _tts.isSpeaking ? _speakingMessageId : null;

  bool get canSpeak => _tts.isAvailable;
  bool get repliesEnabled => _tts.repliesEnabled;
  set repliesEnabled(bool value) => _tts.repliesEnabled = value;

  /// The microphone button: starts listening, or stops and sends what was heard.
  Future<void> toggleListening() async {
    switch (_state) {
      case VoiceState.listening:
        await stopListening();
      case VoiceState.requestingPermission || VoiceState.processing:
        return;
      case VoiceState.idle || VoiceState.speaking || VoiceState.error:
        await startListening();
    }
  }

  Future<void> startListening() async {
    if (_state == VoiceState.listening ||
        _state == VoiceState.processing ||
        _state == VoiceState.requestingPermission) {
      return;
    }
    _log('mic tapped');
    if (!_voice.isAvailable) return _fail(VoiceErrorKind.unavailable);

    // Never listen while a reply is being read aloud: the microphone would hear it.
    await stopSpeaking();
    _error = null;
    _transcript = '';
    _set(VoiceState.requestingPermission);

    if (!await _ensurePermission() || _disposed) return;

    _set(VoiceState.listening);
    final String? text;
    try {
      text = await _voice.listen(onPartialResult: (words) {
        if (_disposed || _state != VoiceState.listening) return;
        _transcript = words;
        notifyListeners();
      });
    } on VoiceInputException catch (e) {
      _log('listen failed: ${e.kind.name}');
      return _fail(e.kind);
    } catch (e) {
      _log('listen failed: ${e.runtimeType}');
      return _fail(VoiceErrorKind.unknown);
    }
    if (_disposed) return;

    // Cancelled (e.g. the user left the screen): nothing is sent.
    if (text == null) return _reset();
    if (text.isEmpty) return _fail(VoiceErrorKind.noSpeech);

    _transcript = '';
    _set(VoiceState.idle);
    _log('sending recognized text');
    await send(text);
    _log('send complete');
  }

  /// Ends the utterance; what was heard so far is sent once.
  Future<void> stopListening() async {
    if (_state != VoiceState.listening) return;
    _set(VoiceState.processing);
    await _voice.stopListening();
  }

  /// Discards the utterance; nothing is sent.
  Future<void> cancelListening() async {
    if (_state == VoiceState.listening || _state == VoiceState.processing) {
      await _voice.cancelListening();
    }
  }

  /// Sends a typed or spoken message and reads the reply aloud if "Voice replies" is on.
  Future<void> send(String text) async {
    await stopSpeaking();
    final reply = await _send(text);
    if (_disposed || reply == null || !_tts.repliesEnabled) return;
    // A reply that arrives while the user has started talking again is not read over them.
    if (_state != VoiceState.idle) return;
    await speakMessage(reply);
  }

  /// The speaker button on a reply: reads it aloud, or stops if it is the one being read.
  Future<void> toggleSpeaking(ChatMessage message) async {
    if (speakingMessageId == message.id) return stopSpeaking();
    await speakMessage(message);
  }

  Future<void> speakMessage(ChatMessage message) async {
    if (_state == VoiceState.listening || _state == VoiceState.processing) return;
    if (message.isUser || message.content.trim().isEmpty) return;
    _speakingMessageId = message.id;
    // Only the reply's own words; tool results and confirmations are never read out.
    await _tts.speak(message.content);
    if (!_disposed) notifyListeners();
  }

  Future<void> stopSpeaking() async {
    _speakingMessageId = null;
    if (_tts.isSpeaking) await _tts.stop();
  }

  void dismissError() {
    if (_state == VoiceState.error) _reset();
  }

  /// The app went to the background: stop the microphone and any speech right away.
  Future<void> interrupt() async {
    await cancelListening();
    await stopSpeaking();
  }

  /// Checks the real OS permission (the stored account status is never trusted for this),
  /// asks for it after an explanation if the OS still allows asking, and mirrors the result
  /// to the account like the Permissions screen does.
  Future<bool> _ensurePermission() async {
    var status = await _permissions.microphoneStatus();
    var fromRequest = false;
    if (status == PermissionState.denied) {
      if (!await _explainPermission()) {
        if (!_disposed) _fail(VoiceErrorKind.permissionDenied);
        return false;
      }
      status = await _permissions.requestMicrophonePermission();
      fromRequest = true;
    }
    _log('microphone permission: ${status.name}');
    unawaited(_report(status, fromRequest: fromRequest));
    if (_disposed) return false;
    if (status.isUsable) return true;

    _fail(switch (status) {
      PermissionState.permanentlyDenied || PermissionState.restricted => VoiceErrorKind.permissionBlocked,
      PermissionState.unavailable => VoiceErrorKind.unavailable,
      _ => VoiceErrorKind.permissionDenied,
    });
    return false;
  }

  Future<void> _report(PermissionState state, {required bool fromRequest}) async {
    try {
      await _sync.report(AppPermission.microphone, state, fromRequest: fromRequest);
    } catch (_) {
      // Best effort; the Permissions screen shows sync problems.
    }
  }

  void _fail(VoiceErrorKind kind) {
    _error = kind;
    _transcript = '';
    _set(VoiceState.error);
  }

  void _reset() {
    _error = null;
    _transcript = '';
    _set(VoiceState.idle);
  }

  void _set(VoiceState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  void _ttsChanged() {
    if (_disposed) return;
    if (!_tts.isSpeaking) _speakingMessageId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tts.removeListener(_ttsChanged);
    // The services outlive this screen; only stop what this screen started.
    unawaited(_voice.cancelListening());
    unawaited(_tts.stop());
    super.dispose();
  }
}

void _log(String message) {
  if (kDebugMode) debugPrint('[Voice] $message');
}
