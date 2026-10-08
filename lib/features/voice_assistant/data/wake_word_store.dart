import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The Voice Assistant choices kept on this phone, per account: Wake Word on/off, whether answers
/// may show on the lock screen, and Voice replies. Only these switches; never audio, transcripts or
/// anything about the microphone. They are per phone on purpose: the wake word listens on this
/// phone's microphone, so another phone signed in to the same account does not start listening.
class WakeWordStore {
  WakeWordStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
            );

  final FlutterSecureStorage _storage;

  static String _enabledKey(String userId) => 'wake_word_enabled_$userId';
  static String _lockScreenKey(String userId) => 'wake_word_lock_screen_$userId';
  static String _voiceRepliesKey(String userId) => 'voice_replies_$userId';

  Future<bool> isEnabled(String userId) async => await _read(_enabledKey(userId)) == 'true';
  Future<void> setEnabled(String userId, bool on) => _set(_enabledKey(userId), on);

  /// Answers show above the lock screen without unlocking. Off unless the user turns it on.
  Future<bool> lockScreenAnswers(String userId) async => await _read(_lockScreenKey(userId)) == 'true';
  Future<void> setLockScreenAnswers(String userId, bool on) => _set(_lockScreenKey(userId), on);

  /// "Voice replies", so a hands-free question can be answered aloud after the app restarts.
  Future<bool> voiceReplies(String userId) async => await _read(_voiceRepliesKey(userId)) == 'true';
  Future<void> setVoiceReplies(String userId, bool on) => _set(_voiceRepliesKey(userId), on);

  Future<void> _set(String key, bool on) => on ? _write(key, 'true') : _delete(key);

  // Storage problems must never crash the app; they only lose the stored switch.
  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      debugPrint('Wake word store read failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('Wake word store write failed: ${e.runtimeType}');
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('Wake word store delete failed: ${e.runtimeType}');
    }
  }
}
