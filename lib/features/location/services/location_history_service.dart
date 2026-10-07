import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../auth/services/auth_service.dart';
import '../data/location_api.dart';
import '../models/location_history_filter.dart';
import '../models/location_record.dart';
import 'location_service.dart';

export '../models/location_history_filter.dart';

/// Why the history could not be loaded, so the screen can say something useful.
enum LocationHistoryErrorKind { noConnection, serverUnavailable, invalidDate, notAllowed, other }

class LocationHistoryError {
  const LocationHistoryError(this.kind, this.message);

  factory LocationHistoryError.from(ApiException e) {
    final status = e.statusCode;
    return switch (status) {
      null => LocationHistoryError(LocationHistoryErrorKind.noConnection,
          'No internet connection. Check your connection and try again.'),
      400 => LocationHistoryError(LocationHistoryErrorKind.invalidDate, e.message),
      401 || 403 => const LocationHistoryError(LocationHistoryErrorKind.notAllowed,
          "You don't have access to this history. Please log in again."),
      >= 500 => const LocationHistoryError(LocationHistoryErrorKind.serverUnavailable,
          'The server is unavailable right now. Please try again later.'),
      _ => LocationHistoryError(LocationHistoryErrorKind.other, e.message),
    };
  }

  final LocationHistoryErrorKind kind;

  /// Safe to show to the user.
  final String message;
}

/// The signed-in user's saved locations, kept in memory for the Location screen.
///
/// Holds one query at a time (recent history, a quick filter or chosen dates) with its
/// results, loading and error state. Loading history never touches GPS or location
/// permission: it only reads what was already saved on the server.
class LocationHistoryService extends ChangeNotifier {
  LocationHistoryService({required LocationApi api, required AuthService authService})
      : _api = api,
        _auth = authService {
    _auth.addListener(_onAuthChanged);
  }

  final LocationApi _api;
  final AuthService _auth;
  /// The account the state below belongs to.
  String? _ownerId;

  /// Bumped for every request and on account change, so a late answer to an earlier
  /// request (or for another account) never overwrites what is shown now.
  int _generation = 0;

  LocationHistoryQuery _query = const LocationHistoryQuery.recent();
  List<LocationRecord> _records = const [];
  bool _hasMore = false;
  bool _loading = false;
  LocationHistoryError? _error;

  /// What [records] answer.
  LocationHistoryQuery get query => _query;

  /// Newest first for recent history; oldest first for a date search.
  List<LocationRecord> get records => _records;

  /// More locations matched than the server returns at once.
  bool get hasMore => _hasMore;

  bool get loading => _loading;

  /// Why the last load failed, or null.
  LocationHistoryError? get error => _error;

  /// Reloads the current query. Never throws: a failure is kept in [error].
  Future<void> load() => _run(_query);

  /// Switches to [query] and loads it. Never throws: a failure is kept in [error].
  Future<void> search(LocationHistoryQuery query) => _run(query);

  /// Loads one quick filter, e.g. [LocationHistoryFilter.yesterday].
  Future<void> searchFilter(LocationHistoryFilter filter, {DateTime? now}) =>
      search(LocationHistoryQuery.preset(filter, now: now));

  Future<void> searchDate(DateTime day) => search(LocationHistoryQuery.date(day));

  Future<void> searchRange(DateTime start, DateTime end) => search(LocationHistoryQuery.range(start, end));

  Future<void> _run(LocationHistoryQuery query) async {
    final generation = ++_generation;
    final userId = _auth.currentUser?.id;
    _ownerId = userId;
    if (query != _query) {
      // Results for another query must never sit under this one's label.
      _records = const [];
      _hasMore = false;
    }
    _query = query;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final page = await _auth.authorized((token) => _api.searchHistory(token, range: query.range));
      if (generation != _generation || _auth.currentUser?.id != userId) return;
      _records = List.unmodifiable(page.records);
      _hasMore = page.hasMore;
    } on ApiException catch (e) {
      if (generation != _generation) return;
      _error = LocationHistoryError.from(e);
    }
    _loading = false;
    notifyListeners();
  }

  // "Today's Travel": today's places, kept apart from the search above so it always shows today.
  int _todayGeneration = 0;
  List<LocationRecord> _today = const [];
  bool _todayLoading = false;
  LocationHistoryError? _todayError;

  /// Every location saved today (manual and automatic), oldest first.
  List<LocationRecord> get todayRecords => _today;
  bool get todayLoading => _todayLoading;
  LocationHistoryError? get todayError => _todayError;

  /// Loads today's places on the device's calendar. Never throws.
  Future<void> loadToday({DateTime? now}) async {
    final generation = ++_todayGeneration;
    final userId = _auth.currentUser?.id;
    _ownerId = userId;
    _todayLoading = true;
    _todayError = null;
    notifyListeners();
    try {
      final range = HistoryDateRange.day(now ?? DateTime.now());
      final page = await _auth.authorized((token) => _api.searchHistory(token, range: range));
      if (generation != _todayGeneration || _auth.currentUser?.id != userId) return;
      _today = List.unmodifiable(page.records);
    } on ApiException catch (e) {
      if (generation != _todayGeneration) return;
      _todayError = LocationHistoryError.from(e);
    }
    _todayLoading = false;
    notifyListeners();
  }

  /// Saves [location] to the user's account, then reloads the history shown.
  /// Throws [ApiException] only if saving fails; a failed reload is kept in [error].
  Future<LocationRecord> save(DeviceLocation location) async {
    final saved = await _auth.authorized((token) => _api.saveLocation(token, location));
    await Future.wait([load(), loadToday()]);
    return saved;
  }

  /// Permanently deletes the user's saved locations; returns how many were removed.
  Future<int> clear() async {
    final deleted = await _auth.authorized(_api.clearHistory);
    _generation++;
    _todayGeneration++;
    _records = const [];
    _hasMore = false;
    _today = const [];
    notifyListeners();
    return deleted;
  }

  // Never show one user's locations to the next account on this device.
  void _onAuthChanged() {
    if (_auth.currentUser?.id != _ownerId) {
      _generation++;
      _query = const LocationHistoryQuery.recent();
      _records = const [];
      _hasMore = false;
      _loading = false;
      _error = null;
      _ownerId = null;
      _todayGeneration++;
      _today = const [];
      _todayLoading = false;
      _todayError = null;
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
