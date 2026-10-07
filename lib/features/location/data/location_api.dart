import '../../../core/api/api_client.dart';
import '../models/location_history_filter.dart';
import '../models/location_record.dart';
import '../services/location_service.dart';

/// The server never returns more locations than this in one response.
const maxHistoryResults = 50;

/// One response from the history endpoint.
class LocationHistoryPage {
  const LocationHistoryPage(this.records, {this.hasMore = false});

  final List<LocationRecord> records;

  /// More locations matched than were returned.
  final bool hasMore;
}

/// What happened to an automatic location sent to the server.
class AutomaticUploadResult {
  const AutomaticUploadResult.saved(LocationRecord this.record) : duplicate = false;
  const AutomaticUploadResult.duplicate()
      : record = null,
        duplicate = true;

  /// The stored record, or null when the server already had this place.
  final LocationRecord? record;

  /// The server skipped it: the user already has a location here at about this time.
  final bool duplicate;
}

/// Raw calls to the backend's /api/location endpoints. The server identifies the user
/// from the token, so no user ID is ever sent.
class LocationApi {
  LocationApi(this._client);

  final ApiClient _client;

  /// Saves a location the user asked for ("Get Current Location").
  Future<LocationRecord> saveLocation(String token, DeviceLocation location) async {
    final json = await _client.post('/api/location', token: token, body: _body(location, LocationSource.manual));
    return LocationRecord.fromJson(json['location'] as Map<String, dynamic>);
  }

  /// Sends a place found by Automatic Location History. The server may skip it as a duplicate
  /// (e.g. a retried upload), which is not an error.
  Future<AutomaticUploadResult> saveAutomaticLocation(String token, DeviceLocation location) async {
    final json = await _client.post('/api/location', token: token, body: _body(location, LocationSource.automatic));
    if (json['saved'] == false) return const AutomaticUploadResult.duplicate();
    return AutomaticUploadResult.saved(LocationRecord.fromJson(json['location'] as Map<String, dynamic>));
  }

  static Map<String, Object?> _body(DeviceLocation location, LocationSource source) => {
      'latitude': location.latitude,
      'longitude': location.longitude,
      if (location.accuracy != null) 'accuracy': location.accuracy,
      'placeName': _limit(location.placeName, 255),
      'address': _limit(location.address, 1000),
      'street': _limit(location.street, 255),
      'locality': _limit(location.locality, 255),
      'city': _limit(location.city, 255),
      'state': _limit(location.state, 255),
      'postalCode': _limit(location.postalCode, 32),
      'country': _limit(location.country, 255),
      'capturedAt': location.capturedAt.toUtc().toIso8601String(),
      'source': source.apiValue,
    };

  /// The user's own most recent locations, newest first.
  Future<List<LocationRecord>> getHistory(String token, {int limit = maxHistoryResults}) async =>
      (await searchHistory(token, limit: limit)).records;

  /// The user's own locations. Without [range], the most recent ones, newest first. With it,
  /// those saved on those local days, oldest first.
  ///
  /// Only date-only values are sent, with the device's UTC offset, so the server can tell
  /// which instants make up the user's local days.
  Future<LocationHistoryPage> searchHistory(String token, {HistoryDateRange? range, int limit = maxHistoryResults}) async {
    final query = {
      'limit': '$limit',
      if (range != null) ...{
        'startDate': formatApiDate(range.start),
        'endDate': formatApiDate(range.end),
        'utcOffsetMinutes': '${range.start.timeZoneOffset.inMinutes}',
      },
    };
    final json = await _client.get('/api/location/history?${Uri(queryParameters: query).query}', token: token);
    final records = json['locations'];
    final result = <LocationRecord>[];
    if (records is List) {
      for (final record in records.whereType<Map<String, dynamic>>()) {
        try {
          result.add(LocationRecord.fromJson(record));
        } on FormatException {
          // Skip a malformed entry rather than hiding the whole history.
        }
      }
    }
    return LocationHistoryPage(result, hasMore: json['hasMore'] == true);
  }

  /// Deletes all of the user's saved locations; returns how many were removed.
  Future<int> clearHistory(String token) async {
    final json = await _client.delete('/api/location/history', token: token);
    return (json['deleted'] as num?)?.toInt() ?? 0;
  }

  // Geocoder text is device-provided; trim it to the server's limits rather than lose the
  // whole location to a validation error.
  static String? _limit(String? value, int max) =>
      value == null || value.length <= max ? value : value.substring(0, max);
}
