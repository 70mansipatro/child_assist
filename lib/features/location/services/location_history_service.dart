import 'package:flutter/foundation.dart';

import '../../auth/services/auth_service.dart';
import '../data/location_api.dart';
import '../models/location_record.dart';
import 'location_service.dart';

/// The signed-in user's saved locations, kept in memory for the Location screen.
class LocationHistoryService extends ChangeNotifier {
  LocationHistoryService({required LocationApi api, required AuthService authService})
      : _api = api,
        _auth = authService {
    _auth.addListener(_onAuthChanged);
  }

  final LocationApi _api;
  final AuthService _auth;
  String? _loadedForUserId;

  List<LocationRecord> _records = const [];

  /// Newest first.
  List<LocationRecord> get records => _records;

  Future<void> load() async {
    final records = await _auth.authorized(_api.getHistory);
    _records = List.unmodifiable(records);
    _loadedForUserId = _auth.currentUser?.id;
    notifyListeners();
  }

  /// Saves [location] to the user's account and reloads the history.
  Future<LocationRecord> save(DeviceLocation location) async {
    final saved = await _auth.authorized((token) => _api.saveLocation(token, location));
    await load();
    return saved;
  }

  /// Permanently deletes the user's saved locations; returns how many were removed.
  Future<int> clear() async {
    final deleted = await _auth.authorized(_api.clearHistory);
    _records = const [];
    notifyListeners();
    return deleted;
  }

  // Never show one user's locations to the next account on this device.
  void _onAuthChanged() {
    if (_auth.currentUser?.id != _loadedForUserId) {
      _records = const [];
      _loadedForUserId = null;
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
