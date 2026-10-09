import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/permissions/permission_service.dart';
import '../../permissions/services/permission_sync_service.dart';
import '../../voice_assistant/services/wake_phrase.dart';
import '../../voice_assistant/services/wake_word_service.dart';
import '../models/chat_message.dart';
import 'text_to_speech_service.dart';
import 'voice_input.dart';

/// Where a voice interaction is. Exactly one at a time.
enum VoiceState { idle, requestingPermission, listening, processing, speaking, error }

/// Tap-to-talk for the chat screen: checks the microphone permission, listens for one
/// utterance, sends the transcript through the normal chat send, and reads replies aloud when
/// "Voice replies" is on. The screen only draws [state]; all voice logic lives here.
///
/// After "Hey Child" ([listenAfterWakeWord]) the same listening, send and read-aloud steps run
/// without a tap; only the question is sent, never the wake phrase.
class VoiceChatController extends ChangeNotifier {
  VoiceChatController({
    required VoiceInput voiceInput,
    required TextToSpeechService textToSpeech,
    required PermissionService permissionService,
    required PermissionSyncService permissionSyncService,
    required Future<ChatMessage?> Function(String text) send,
    required Future<bool> Function() explainPermission,
    WakeWordService? wakeWord,
    this.wakeQuestionTimeout = const Duration(seconds: 15),
    this.wakeQuestionStartWindow = const Duration(seconds: 8),
    this.wakeQuestionEndSilence = const Duration(milliseconds: 1800),
  })  : _voice = voiceInput,
        _tts = textToSpeech,
        _permissions = permissionService,
        _sync = permissionSyncService,
        _send = send,
        _explainPermission = explainPermission,
        _wakeWord = wakeWord {
    _tts.addListener(_ttsChanged);
    _wakeWord?.addListener(_wakeChanged);
  }

  final VoiceInput _voice;
  final TextToSpeechService _tts;
  final PermissionService _permissions;
  final PermissionSyncService _sync;

  /// "Hey Child", when available: its microphone is released while the user talks here.
  final WakeWordService? _wakeWord;

  /// The longest a question after the wake phrase may take before listening gives up.
  final Duration wakeQuestionTimeout;

  /// After the cue, how long the user has to start asking. Longer than tap-to-talk's pause: on
  /// the phone, people took a few seconds after the cue before speaking.
  final Duration wakeQuestionStartWindow;

  /// Once words were heard, this much silence ends the question, so the answer is not delayed by
  /// the longer start window.
  final Duration wakeQuestionEndSilence;

  /// The chat's own send; returns the reply, or null if the turn failed.
  final Future<ChatMessage?> Function(String text) _send;

  /// Shows why the microphone is needed before the OS dialog; true if the user continues.
  final Future<bool> Function() _explainPermission;

  VoiceState _state = VoiceState.idle;

  /// A question started by the wake phrase is in progress (not tap-to-talk).
  bool _wakeQuestion = false;
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
    // The wake word's microphone is closed while the phone's recogniser listens here.
    await _wakeWord?.pauseFor(WakeWordService.reasonTalking);
    try {
      text = await _voice.listen(onPartialResult: _heard);
    } on VoiceInputException catch (e) {
      _log('listen failed: ${e.kind.name}');
      return _fail(e.kind);
    } catch (e) {
      _log('listen failed: ${e.runtimeType}');
      return _fail(VoiceErrorKind.unknown);
    } finally {
      // One microphone owner at a time: the recogniser lets go before the wake word reopens it.
      final wake = _wakeWord;
      if (wake != null) unawaited(_voice.releaseMicrophone().whenComplete(() => wake.resumeAfter(WakeWordService.reasonTalking)));
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

  void _heard(String words) {
    if (_disposed || _state != VoiceState.listening) return;
    _transcript = words;
    notifyListeners();
  }

  /// "Hey Child" was heard: listens for the question without a tap, sends only the question
  /// through the same chat send, and reads the reply aloud if "Voice replies" is on. Silence, a
  /// timeout, cancelling or a locked phone the user does not unlock all return quietly to
  /// waiting for the wake phrase. Never shows a permission dialog.
  Future<void> listenAfterWakeWord() async {
    final wake = _wakeWord;
    if (wake == null) return;
    // Already talking with the microphone button: that conversation wins.
    if (_state == VoiceState.listening ||
        _state == VoiceState.processing ||
        _state == VoiceState.requestingPermission) {
      return wake.commandEnded();
    }
    _log('wake word: listening for the question');
    await stopSpeaking();
    if (!_voice.isAvailable) {
      _fail(VoiceErrorKind.unavailable);
      return wake.commandEnded(problem: VoiceErrorKind.unavailable.message);
    }
    final permission = await _permissions.microphoneStatus();
    if (_disposed) return wake.commandEnded();
    if (!permission.isUsable) {
      final kind = permission == PermissionState.permanentlyDenied || permission == PermissionState.restricted
          ? VoiceErrorKind.permissionBlocked
          : VoiceErrorKind.permissionDenied;
      _fail(kind);
      return wake.commandEnded(problem: kind.message);
    }
    if (!await wake.prepareForQuestion() || _disposed) {
      if (!_disposed) _reset();
      return wake.commandEnded();
    }

    _error = null;
    _transcript = '';
    _wakeQuestion = true;
    try {
      await _answerWakeQuestion(wake);
    } finally {
      _wakeQuestion = false;
    }
  }

  Future<void> _answerWakeQuestion(WakeWordService wake) async {
    // "Hi Child, what is my name?" in one breath: the phone already heard the question.
    final inline = stripWakePhrase(wake.takeInlineQuestion());
    if (inline.isNotEmpty) {
      wake.commandListening();
      wake.logStep('question heard together with the wake phrase');
      return _sendWakeQuestion(wake, inline);
    }
    _set(VoiceState.listening);
    wake.commandListening();
    wake.logStep('speech recognition starting');
    String? heard;
    Timer? endOfQuestion;
    void partial(String words) {
      _heard(words);
      if (words.trim().isEmpty) return;
      endOfQuestion?.cancel();
      endOfQuestion = Timer(wakeQuestionEndSilence, () {
        wake.logStep('end of question (silence)');
        unawaited(_voice.stopListening());
      });
    }

    try {
      heard = await _voice
          .listen(
            onPartialResult: partial,
            onReady: wake.questionReady,
            onSoundLevel: wake.questionSoundLevel,
            pauseFor: wakeQuestionStartWindow,
          )
          .timeout(wakeQuestionTimeout, onTimeout: () async {
        wake.logStep('speech recognition timed out');
        await _voice.cancelListening();
        return null;
      });
    } on VoiceInputException catch (e) {
      endOfQuestion?.cancel();
      wake.logStep('speech recognition failed: ${e.kind.name}');
      await _voice.releaseMicrophone();
      if (!_disposed) _fail(e.kind);
      return wake.commandEnded(problem: e.kind.message);
    } catch (e) {
      endOfQuestion?.cancel();
      wake.logStep('speech recognition failed: ${e.runtimeType}');
      await _voice.releaseMicrophone();
      if (!_disposed) _fail(VoiceErrorKind.unknown);
      return wake.commandEnded(problem: VoiceErrorKind.unknown.message);
    }
    endOfQuestion?.cancel();
    // The recogniser lets go of the microphone before anything else uses it.
    await _voice.releaseMicrophone();
    wake.logStep('speech recognition microphone released');
    if (_disposed) return wake.commandEnded();

    final question = stripWakePhrase(heard ?? '');
    if (question.isEmpty) {
      // Only the wake phrase, or nothing (or switched off meanwhile): back to waiting.
      wake.logStep(heard == null ? 'question cancelled' : 'no question heard');
      _reset();
      return wake.commandEnded();
    }
    return _sendWakeQuestion(wake, question);
  }

  /// Sends the question through the normal chat send and reads the answer aloud.
  Future<void> _sendWakeQuestion(WakeWordService wake, String question) async {
    _transcript = '';
    _set(VoiceState.idle);
    wake.commandHeard();
    // Only the question's length: never what was said.
    wake.logStep('question recognised (${question.length} chars); chat request started');
    await stopSpeaking();
    final reply = await _send(question);
    wake.logStep(reply == null ? 'chat request ended without an answer' : 'chat request completed; answer shown');
    if (!_disposed && reply != null && _tts.repliesEnabled && _state == VoiceState.idle && wake.enabled) {
      // An answer is never read out over the lock screen unless the user allowed it.
      if (await wake.mayRevealAnswer()) {
        await speakMessage(reply);
      } else {
        wake.logStep('answer not read aloud: the phone is locked');
      }
    }
    wake.commandFinished(problem: reply == null ? noAnswerMessage : null);
  }

  /// Shown briefly after a hands-free question that got no answer (e.g. no connection).
  static const noAnswerMessage = "I couldn't get an answer right now. Say “Hey Child” to try again.";

  /// Wake Word switched off (in Settings, from its notification, logout) during a wake question:
  /// the recogniser's microphone closes and nothing more is said.
  void _wakeChanged() {
    final wake = _wakeWord;
    if (!_wakeQuestion || wake == null || wake.state != WakeWordState.disabled) return;
    unawaited(_voice.cancelListening());
    unawaited(stopSpeaking());
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

  /// An answer that came after its turn (what a photo shows, once the phone sent it): read aloud
  /// like a reply when "Voice replies" is on (cutting short "Let me look at the photo"), never
  /// while the user is talking.
  Future<void> speakLateReply(ChatMessage message) async {
    if (_disposed || !_tts.repliesEnabled || _state != VoiceState.idle) return;
    if (_tts.isSpeaking) await _tts.stop();
    await speakMessage(message);
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
  ///
  /// [keepWakeQuestion]: a question started by the wake phrase goes on (it is meant to work with
  /// Child Assist in the background, e.g. after the user presses Home while asking); tap-to-talk
  /// still stops.
  Future<void> interrupt({bool keepWakeQuestion = false}) async {
    if (keepWakeQuestion && _wakeQuestion) return;
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
    _wakeWord?.removeListener(_wakeChanged);
    // The services outlive this screen; only stop what this screen started.
    unawaited(_voice.cancelListening());
    unawaited(_tts.stop());
    super.dispose();
  }
}

void _log(String message) {
  if (kDebugMode) debugPrint('[Voice] $message');
}
