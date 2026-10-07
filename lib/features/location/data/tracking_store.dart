import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/automatic_tracking.dart';

/// What Automatic Location History keeps on the phone, per account: whether the user switched it
/// on, the last saved place (so a restart does not save the same place again) and places waiting
/// to be uploaded. Location data is kept in platform secure storage, never in plain preferences,
/// and no token or other credential is ever written here.
class TrackingStore {
  TrackingStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
            );

  final FlutterSecureStorage _storage;

  static String _enabledKey(String userId) => 'auto_location_enabled_$userId';
  static String _lastPlaceKey(String userId) => 'auto_location_last_place_$userId';
  static String _queueKey(String userId) => 'auto_location_queue_$userId';

  Future<bool> isEnabled(String userId) async => await _read(_enabledKey(userId)) == 'true';

  Future<void> setEnabled(String userId, bool enabled) =>
      enabled ? _write(_enabledKey(userId), 'true') : _delete(_enabledKey(userId));

  Future<TrackedPoint?> lastPlace(String userId) async {
    final raw = await _read(_lastPlaceKey(userId));
    if (raw == null) return null;
    try {
      return TrackedPoint.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<void> setLastPlace(String userId, TrackedPoint? place) => place == null
      ? _delete(_lastPlaceKey(userId))
      : _write(_lastPlaceKey(userId), jsonEncode(place.toJson()));

  /// Oldest first.
  Future<List<TrackedPoint>> queue(String userId) async {
    final raw = await _read(_queueKey(userId));
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [for (final item in decoded) ?TrackedPoint.fromJson(item)];
    } on FormatException {
      return [];
    }
  }

  Future<void> setQueue(String userId, List<TrackedPoint> points) => points.isEmpty
      ? _delete(_queueKey(userId))
      : _write(_queueKey(userId), jsonEncode([for (final p in points) p.toJson()]));

  /// Removes everything kept for the account (on logout).
  Future<void> clear(String userId) async {
    await _delete(_enabledKey(userId));
    await _delete(_lastPlaceKey(userId));
    await _delete(_queueKey(userId));
  }

  // Storage problems must never crash tracking or the app; they only lose the stored value.
  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      debugPrint('Tracking store read failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('Tracking store write failed: ${e.runtimeType}');
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('Tracking store delete failed: ${e.runtimeType}');
    }
  }
}
