import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Reads Child Assist's replies aloud. "Voice replies" is off by default; when it is on, each
/// new reply is spoken, and the user can stop it at any time.
abstract class TextToSpeechService extends ChangeNotifier {
  /// Whether this build can speak at all.
  bool get isAvailable;

  /// The user's "Voice replies" choice. Off until they turn it on.
  bool get repliesEnabled;
  set repliesEnabled(bool value);

  /// True while something is being spoken.
  bool get isSpeaking;

  /// Speaks [text], stopping anything already being spoken. Completes when speech starts.
  Future<void> speak(String text);

  /// Stops speaking immediately.
  Future<void> stop();

  Future<void> pause();

  Future<void> resume();
}

/// Turns a reply into what may be read aloud: the reply's words only. Links, code blocks, raw
/// JSON, token-like strings and long identifiers are left out, and markdown symbols are dropped.
String speakableText(String text) {
  var out = text
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'`[^`]*`'), ' ')
      .replaceAll(RegExp(r'\{[\s\S]*?\}'), ' ')
      .replaceAll(RegExp(r'https?://\S+|www\.\S+'), ' ')
      // JWT-like tokens and long ids/keys (hex, base64, UUIDs).
      .replaceAll(RegExp(r'\beyJ[\w-]+\.[\w-]+(\.[\w-]+)?'), ' ')
      .replaceAll(RegExp(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'), ' ')
      .replaceAll(RegExp(r'\b(?=[\w-]*\d)[\w-]{24,}\b'), ' ')
      .replaceAll(RegExp(r'[*_#>~|]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (out.length > 4000) out = out.substring(0, 4000);
  return out;
}

/// Text-to-speech through the device's own engine (`flutter_tts`).
class FlutterTextToSpeechService extends TextToSpeechService {
  FlutterTextToSpeechService({FlutterTts? tts, bool? isWeb, TargetPlatform? platform})
      : _ttsOverride = tts,
        _isWeb = isWeb ?? kIsWeb,
        _platform = platform ?? defaultTargetPlatform;

  // Created on first use, so the plugin is not touched until something is spoken.
  final FlutterTts? _ttsOverride;
  FlutterTts? _ttsInstance;
  final bool _isWeb;
  final TargetPlatform _platform;

  bool _repliesEnabled = false;
  bool _speaking = false;
  bool _configured = false;
  String? _current;

  @override
  bool get isAvailable =>
      !_isWeb && (_platform == TargetPlatform.android || _platform == TargetPlatform.iOS);

  @override
  bool get repliesEnabled => _repliesEnabled;

  @override
  set repliesEnabled(bool value) {
    if (value == _repliesEnabled) return;
    _repliesEnabled = value;
    if (!value) unawaited(stop());
    notifyListeners();
  }

  @override
  bool get isSpeaking => _speaking;

  FlutterTts get _tts {
    final tts = _ttsInstance ??= _ttsOverride ?? FlutterTts();
    if (!_configured) {
      _configured = true;
      tts.setStartHandler(() => _setSpeaking(true));
      tts.setCompletionHandler(() => _setSpeaking(false));
      tts.setCancelHandler(() => _setSpeaking(false));
      tts.setErrorHandler((_) => _setSpeaking(false));
    }
    return tts;
  }

  @override
  Future<void> speak(String text) async {
    if (!isAvailable) return;
    final speakable = speakableText(text);
    if (speakable.isEmpty) return;
    await stop();
    _current = speakable;
    _setSpeaking(true);
    try {
      await _tts.speak(speakable);
    } catch (e) {
      debugPrint('Text-to-speech failed: ${e.runtimeType}');
      _setSpeaking(false);
    }
  }

  @override
  Future<void> stop() async {
    _current = null;
    _setSpeaking(false);
    // Nothing was ever spoken, so there is nothing to stop.
    if (_ttsInstance == null) return;
    try {
      await _tts.stop();
    } catch (e) {
      debugPrint('Text-to-speech stop failed: ${e.runtimeType}');
    }
  }

  @override
  Future<void> pause() async {
    if (!_speaking) return;
    try {
      await _tts.pause();
    } catch (e) {
      debugPrint('Text-to-speech pause failed: ${e.runtimeType}');
    }
    _setSpeaking(false);
  }

  /// Android has no native resume: speaking the same text again continues where it paused.
  @override
  Future<void> resume() async {
    final text = _current;
    if (text == null || _speaking) return;
    _setSpeaking(true);
    try {
      await _tts.speak(text);
    } catch (e) {
      debugPrint('Text-to-speech resume failed: ${e.runtimeType}');
      _setSpeaking(false);
    }
  }

  void _setSpeaking(bool value) {
    if (value == _speaking) return;
    _speaking = value;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}

/// For builds without text-to-speech.
class SilentTextToSpeechService extends TextToSpeechService {
  @override
  bool get isAvailable => false;

  @override
  bool get repliesEnabled => false;

  @override
  set repliesEnabled(bool value) {}

  @override
  bool get isSpeaking => false;

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}
}
